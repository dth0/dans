package httpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strings"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/gorillamux"
	nethttpmiddleware "github.com/oapi-codegen/nethttp-middleware"

	contractdoc "github.com/ncode/dans/api/openapi"
	"github.com/ncode/dans/internal/contract"
	"github.com/ncode/dans/internal/httpapi"
)

// RouteInfo is the reviewed contract identity of the current request.
type RouteInfo struct {
	Template       string
	OperationID    string
	AccessClass    contract.AccessClass
	PathParameters map[string]string
}

// NewContractValidation rejects undeclared or contract-invalid requests before
// authentication and records the matched operation for later authorization.
func NewContractValidation(document *openapi3.T) (Middleware, error) {
	if document == nil || document.Paths == nil {
		return nil, errors.New("HTTP contract: missing document")
	}
	router, err := gorillamux.NewRouter(document)
	if err != nil {
		return nil, errors.New("HTTP contract: construct router")
	}
	rootRoutes := make(map[string]*routers.Route)
	for path, pathItem := range document.Paths.Map() {
		for method, operation := range pathItem.Operations() {
			if _, err := operationAccessClass(operation); err != nil {
				return nil, err
			}
			if hasRootServer(operation) {
				rootRoutes[strings.ToUpper(method)+" "+path] = &routers.Route{
					Spec: document, Server: &openapi3.Server{URL: "/"}, Path: path, PathItem: pathItem,
					Method: strings.ToUpper(method), Operation: operation,
				}
			}
		}
	}

	validator := nethttpmiddleware.OapiRequestValidatorWithOptions(document, &nethttpmiddleware.Options{
		Options:               openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc},
		SilenceServersWarning: true,
		ErrorHandlerWithOpts: func(_ context.Context, err error, w http.ResponseWriter, request *http.Request, options nethttpmiddleware.ErrorHandlerOpts) {
			kind := httpapi.KindInvalidRequest
			if options.MatchedRoute == nil {
				kind = httpapi.KindNotFound
			}
			httpapi.WriteError(w, RequestIDFromContext(request.Context()), httpapi.NewError(kind, err))
		},
	})

	return func(next http.Handler) http.Handler {
		validated := validator(next)
		return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
			signIn := request.Method == http.MethodPost && request.URL.Path == "/api/v1/dans/session"
			if !signIn {
				if err := validateJSONSyntax(request); err != nil {
					if httpapi.StatusCode(err) != http.StatusInternalServerError {
						httpapi.WriteError(w, RequestIDFromContext(request.Context()), err)
						return
					}
					kind := httpapi.KindBadRequest
					if errors.As(err, new(*http.MaxBytesError)) {
						kind = httpapi.KindBodyTooLarge
					}
					httpapi.WriteError(w, RequestIDFromContext(request.Context()), httpapi.NewError(kind, err))
					return
				}
			}
			route, root := rootRoutes[request.Method+" "+request.URL.Path]
			var parameters map[string]string
			if !root {
				var routeErr error
				route, parameters, routeErr = router.FindRoute(request)
				if routeErr != nil || hasRootServer(routeOperation(route)) {
					httpapi.WriteError(w, RequestIDFromContext(request.Context()), httpapi.NewError(httpapi.KindNotFound, routeErr))
					return
				}
			}
			accessClass, accessErr := operationAccessClass(route.Operation)
			if accessErr != nil {
				httpapi.WriteError(w, RequestIDFromContext(request.Context()), httpapi.NewError(httpapi.KindUnavailable, accessErr))
				return
			}
			information := RouteInfo{
				Template:       routeTemplate(route.Server, route.Path),
				OperationID:    canonicalOperationID(route.Operation.OperationID),
				AccessClass:    accessClass,
				PathParameters: cloneStrings(parameters),
			}
			AccessMetadataFromContext(request.Context()).SetRoute(information.Template, information.OperationID)
			ctx := context.WithValue(request.Context(), routeInfoKey, information)
			request = request.WithContext(ctx)
			if signIn && information.OperationID == "createBrowserSession" && information.Template == "/api/v1/dans/session" {
				// The handler owns strict bounded credential decoding so invalid sign-in
				// credentials have the same 401 shape. Authentication still checks CSRF.
				next.ServeHTTP(w, request)
				return
			}
			if root {
				input := &openapi3filter.RequestValidationInput{
					Request: request, Route: route, PathParams: parameters,
					Options: &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc},
				}
				if err := openapi3filter.ValidateRequest(request.Context(), input); err != nil {
					httpapi.WriteError(w, RequestIDFromContext(request.Context()), httpapi.NewError(httpapi.KindInvalidRequest, err))
					return
				}
				next.ServeHTTP(w, request)
				return
			}
			validated.ServeHTTP(w, request)
		})
	}, nil
}

// ContractOperationIDs returns the canonical operation IDs of the embedded
// combined contract, as recorded in RouteInfo.
func ContractOperationIDs() (map[string]struct{}, error) {
	document, err := contractdoc.Spec()
	if err != nil || document.Paths == nil {
		return nil, errors.New("HTTP contract: parse embedded contract")
	}
	operations := make(map[string]struct{})
	for _, pathItem := range document.Paths.Map() {
		for _, operation := range pathItem.Operations() {
			operations[canonicalOperationID(operation.OperationID)] = struct{}{}
		}
	}
	return operations, nil
}

// RouteInfoFromContext returns the operation matched by contract validation.
func RouteInfoFromContext(ctx context.Context) (RouteInfo, bool) {
	information, ok := ctx.Value(routeInfoKey).(RouteInfo)
	return information, ok
}

func operationAccessClass(operation *openapi3.Operation) (contract.AccessClass, error) {
	if operation == nil {
		return "", errors.New("HTTP contract: route has no operation")
	}
	value, ok := operation.Extensions["x-dans-access-class"].(string)
	if !ok {
		return "", errors.New("HTTP contract: route is unclassified")
	}
	accessClass := contract.AccessClass(value)
	switch accessClass {
	case contract.AccessAnonymous, contract.AccessAuthenticatedRead, contract.AccessDelegatedWrite, contract.AccessOperatorOnly:
		return accessClass, nil
	default:
		return "", errors.New("HTTP contract: route has unknown access class")
	}
}

func hasRootServer(operation *openapi3.Operation) bool {
	if operation == nil || operation.Servers == nil {
		return false
	}
	for _, server := range *operation.Servers {
		if server != nil && server.URL == "/" {
			return true
		}
	}
	return false
}

func routeOperation(route *routers.Route) *openapi3.Operation {
	if route == nil {
		return nil
	}
	return route.Operation
}

func canonicalOperationID(value string) string {
	if value != "" && value[0] >= 'A' && value[0] <= 'Z' {
		return string(value[0]-'A'+'a') + value[1:]
	}
	return value
}

func validateJSONSyntax(request *http.Request) error {
	if request.Body == nil || !isJSONMediaType(request.Header.Get("Content-Type")) {
		return nil
	}
	body, err := io.ReadAll(request.Body)
	closeErr := request.Body.Close()
	if err := errors.Join(err, closeErr); err != nil {
		return err
	}
	request.Body = io.NopCloser(bytes.NewReader(body))
	if len(bytes.TrimSpace(body)) == 0 {
		return nil
	}
	if !json.Valid(body) {
		return errors.New("malformed JSON request body")
	}
	if err := httpapi.StrictJSON(bytes.NewReader(body), int64(len(body))+1, func(map[string]json.RawMessage) error { return nil }); err != nil {
		return err
	}
	return nil
}

func isJSONMediaType(value string) bool {
	mediaType, _, err := mime.ParseMediaType(value)
	if err != nil {
		return false
	}
	return mediaType == "application/json" || strings.HasSuffix(mediaType, "+json")
}

func routeTemplate(server *openapi3.Server, path string) string {
	if server == nil || server.URL == "" || server.URL == "/" {
		return path
	}
	return strings.TrimSuffix(server.URL, "/") + path
}

func cloneStrings(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	clone := make(map[string]string, len(values))
	for key, value := range values {
		clone[key] = value
	}
	return clone
}
