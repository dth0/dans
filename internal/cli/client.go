package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"reflect"
	"strconv"

	"github.com/google/uuid"
	"github.com/ncode/dans/api"
	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/identifier"
	"github.com/ncode/dans/internal/page"
	"github.com/spf13/cobra"
)

const maxCLIRequestBytes = 1 << 20

type apiResponse interface {
	GetBody() []byte
	Status() string
	StatusCode() int
}

func clientDoer(config Config, override api.HttpRequestDoer) (api.HttpRequestDoer, error) {
	if override != nil {
		return override, nil
	}
	timeout, err := durationSetting("request_timeout", config.RequestTimeout)
	if err != nil {
		return nil, err
	}
	return &http.Client{Timeout: timeout}, nil
}

func onlineClient(cmd *cobra.Command, options Options) (Config, *api.DANSClientWithResponses, error) {
	config, err := loadConfig(cmd, configScopeOnline)
	if err != nil {
		return Config{}, nil, invocationFailure(err)
	}
	token, err := loadAPIToken(config)
	if err != nil {
		return Config{}, nil, invocationFailure(err)
	}
	doer, err := clientDoer(config, options.HTTPClient)
	if err != nil {
		return Config{}, nil, invocationFailure(err)
	}
	client, err := api.NewDANSClientWithResponses(
		config.Endpoint,
		api.WithHTTPClient(doer),
		api.WithRequestEditorFn(func(_ context.Context, request *http.Request) error {
			request.Header.Set("X-API-Key", token.Value())
			return nil
		}),
	)
	if err != nil {
		return Config{}, nil, invocationFailure(fmt.Errorf("configure DANS API client: %w", err))
	}
	return config, client, nil
}

func requireStatus(operation string, response apiResponse, allowed ...int) error {
	if response == nil {
		return runtimeFailure(fmt.Errorf("%s: empty API response", operation))
	}
	for _, status := range allowed {
		if response.StatusCode() == status {
			return nil
		}
	}
	if detail := rateLimitDetail(response); detail != "" {
		return runtimeFailure(fmt.Errorf("%s: DANS API returned %s: %s", operation, response.Status(), detail))
	}
	return runtimeFailure(fmt.Errorf("%s: DANS API returned %s", operation, response.Status()))
}

// rateLimitDetail explains a rate-limit 429 or 413. The CLI never retries:
// the caller decides when to run the command again.
func rateLimitDetail(response apiResponse) string {
	header := responseHeader(response)
	buckets := header.Get("X-DANS-RateLimit-Bucket")
	if buckets == "" {
		return ""
	}
	switch response.StatusCode() {
	case http.StatusTooManyRequests:
		retry := header.Get("Retry-After")
		if seconds, err := strconv.ParseInt(retry, 10, 64); err == nil && seconds > 0 {
			return fmt.Sprintf("rate limited by %s; retry after %d seconds", buckets, seconds)
		}
		return fmt.Sprintf("rate limited by %s", buckets)
	case http.StatusRequestEntityTooLarge:
		return fmt.Sprintf("request cost exceeds the %s rate-limit capacity; split the request", buckets)
	default:
		return ""
	}
}

// responseHeader reads the HTTPResponse field that every generated
// *WithResponses type carries; the shared interface exposes only the body
// and status.
func responseHeader(response apiResponse) http.Header {
	value := reflect.ValueOf(response)
	if value.Kind() == reflect.Pointer {
		if value.IsNil() {
			return nil
		}
		value = value.Elem()
	}
	if value.Kind() != reflect.Struct {
		return nil
	}
	field := value.FieldByName("HTTPResponse")
	if !field.IsValid() || !field.CanInterface() {
		return nil
	}
	httpResponse, _ := field.Interface().(*http.Response)
	if httpResponse == nil {
		return nil
	}
	return httpResponse.Header
}

func transportFailure(operation string, err error) error {
	if err == nil {
		return nil
	}
	return runtimeFailure(fmt.Errorf("%s: %w", operation, err))
}

func emitAPIResult(cmd *cobra.Command, config Config, value any) error {
	pretty, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return runtimeFailure(fmt.Errorf("format result: %w", err))
	}
	if err := writeResult(cmd.OutOrStdout(), config.Output, string(pretty), value); err != nil {
		return runtimeFailure(fmt.Errorf("write result: %w", err))
	}
	return nil
}

func emitExpected[T any](cmd *cobra.Command, config Config, operation string, response apiResponse, status int, value *T) error {
	if err := requireStatus(operation, response, status); err != nil {
		return err
	}
	if value == nil {
		return runtimeFailure(fmt.Errorf("%s: API response did not contain the declared JSON body", operation))
	}
	return emitAPIResult(cmd, config, *value)
}

func emitSuccess(cmd *cobra.Command, config Config) error {
	value := struct {
		Status string `json:"status"`
	}{Status: "ok"}
	return emitAPIResult(cmd, config, value)
}

func decodeData[T any](cmd *cobra.Command) (T, error) {
	var zero T
	path, err := cmd.Flags().GetString("data")
	if err != nil {
		return zero, invocationFailure(fmt.Errorf("read --data: %w", err))
	}
	if path == "" {
		return zero, invocationFailure(fmt.Errorf("--data is required"))
	}

	reader := cmd.InOrStdin()
	var file *os.File
	if path != "-" {
		file, err = os.Open(path)
		if err != nil {
			return zero, invocationFailure(fmt.Errorf("open data %q: %w", path, err))
		}
		reader = file
	}

	var value T
	decodeErr := httpapi.StrictJSON(reader, maxCLIRequestBytes, func(decoded T) error {
		value = decoded
		return nil
	})
	if file != nil {
		if closeErr := file.Close(); decodeErr == nil && closeErr != nil {
			decodeErr = fmt.Errorf("close data %q: %w", path, closeErr)
		}
	}
	if decodeErr != nil {
		return zero, invocationFailure(fmt.Errorf("decode data %q: %w", path, decodeErr))
	}
	return value, nil
}

func addDataFlag(command *cobra.Command) {
	command.Flags().String("data", "", "JSON request body file, or - for stdin")
}

func parseResourceID(value string) (api.ResourceID, error) {
	if err := identifier.ValidateUUID(value); err != nil {
		return api.ResourceID{}, invocationFailure(fmt.Errorf("invalid resource ID %q", value))
	}
	parsed, err := uuid.Parse(value)
	if err != nil {
		return api.ResourceID{}, invocationFailure(fmt.Errorf("invalid resource ID %q", value))
	}
	return parsed, nil
}

func addPageFlags(command *cobra.Command) {
	command.Flags().Int("limit", 0, "Maximum number of results")
	command.Flags().String("cursor", "", "Opaque pagination cursor")
}

func pageFlags(command *cobra.Command) (*api.Limit, *api.Cursor, error) {
	limit, err := command.Flags().GetInt("limit")
	if err != nil {
		return nil, nil, invocationFailure(fmt.Errorf("read --limit: %w", err))
	}
	if limit < 0 || limit > page.MaxLimit {
		return nil, nil, invocationFailure(fmt.Errorf("--limit must be between 1 and %d", page.MaxLimit))
	}
	var apiLimit *api.Limit
	if command.Flags().Changed("limit") {
		if limit == 0 {
			return nil, nil, invocationFailure(fmt.Errorf("--limit must be between 1 and %d", page.MaxLimit))
		}
		value := api.Limit(limit)
		apiLimit = &value
	}
	cursor, err := command.Flags().GetString("cursor")
	if err != nil {
		return nil, nil, invocationFailure(fmt.Errorf("read --cursor: %w", err))
	}
	var apiCursor *api.Cursor
	if cursor != "" {
		value := api.Cursor(cursor)
		apiCursor = &value
	}
	return apiLimit, apiCursor, nil
}

func valueFlag(command *cobra.Command, name string) (*string, error) {
	value, err := command.Flags().GetString(name)
	if err != nil {
		return nil, invocationFailure(fmt.Errorf("read --%s: %w", name, err))
	}
	if value == "" {
		return nil, nil
	}
	return &value, nil
}

func boolFlag(command *cobra.Command, name string) (*bool, error) {
	if !command.Flags().Changed(name) {
		return nil, nil
	}
	value, err := command.Flags().GetBool(name)
	if err != nil {
		return nil, invocationFailure(fmt.Errorf("read --%s: %w", name, err))
	}
	return &value, nil
}
