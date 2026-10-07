package cli

import (
	"bytes"
	"fmt"
	"io"
	"net/url"
	"os"
	"unicode/utf8"

	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/identifier"
	"github.com/ncode/dans/internal/ratelimit"
	"github.com/ncode/dans/internal/upstream"
)

const maxSecretBytes = 64 << 10

type secretSource struct {
	name     string
	env      string
	file     string
	validate func(string) error
}

func loadAPIToken(config Config) (httpapi.Secret, error) {
	return loadSecret(secretSource{
		name:     "DANS API token",
		env:      "DANS_API_TOKEN",
		file:     config.APITokenFile,
		validate: identifier.ValidateToken,
	})
}

func loadDatabaseURL(config Config) (httpapi.Secret, error) {
	return loadSecret(secretSource{
		name: "database URL",
		env:  "DANS_DATABASE_URL",
		file: config.DatabaseURLFile,
		validate: func(value string) error {
			parsed, err := url.Parse(value)
			if err != nil || parsed.Scheme != "postgres" && parsed.Scheme != "postgresql" {
				return fmt.Errorf("must be a PostgreSQL URL")
			}
			return nil
		},
	})
}

func loadRedisURL(config Config) (httpapi.Secret, error) {
	return loadSecret(secretSource{
		name: "rate-limit Redis URL",
		env:  "DANS_REDIS_URL",
		file: config.RedisURLFile,
		validate: func(value string) error {
			return ratelimit.ParseRedisURL(value)
		},
	})
}

// readBoundedConfigFile reads one regular, non-secret configuration document.
func readBoundedConfigFile(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %q: %w", path, err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect %q: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("read %q: not a regular file", path)
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, fmt.Errorf("read %q: %w", path, err)
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("read %q: file exceeds %d bytes", path, limit)
	}
	return data, nil
}

func loadPowerDNSAPIKey(config Config) (httpapi.Secret, error) {
	environment, _ := os.LookupEnv("DANS_POWERDNS_API_KEY")
	secret, err := upstream.LoadKey(upstream.KeySources{
		Environment:      environment,
		File:             config.PowerDNSAPIKeyFile,
		RenderedFragment: config.PowerDNSConfigFile,
	})
	if err != nil {
		return httpapi.Secret{}, fmt.Errorf("load PowerDNS API key: %w", err)
	}
	return secret, nil
}

func loadSecret(source secretSource) (httpapi.Secret, error) {
	environment, environmentSet := os.LookupEnv(source.env)
	if environment == "" {
		environmentSet = false
	}
	fileSet := source.file != ""
	if environmentSet == fileSet {
		return httpapi.Secret{}, fmt.Errorf("load %s: exactly one of %s or its *_file setting is required", source.name, source.env)
	}

	var (
		value string
		err   error
	)
	if environmentSet {
		value, err = validateSecret([]byte(environment))
	} else {
		value, err = readSecretFile(source.file)
	}
	if err != nil {
		return httpapi.Secret{}, fmt.Errorf("load %s: %w", source.name, err)
	}
	if source.validate != nil {
		if err := source.validate(value); err != nil {
			return httpapi.Secret{}, fmt.Errorf("load %s: malformed value", source.name)
		}
	}
	return httpapi.NewSecret(value), nil
}

func readSecretFile(path string) (string, error) {
	data, err := readBoundedFile(path)
	if err != nil {
		return "", err
	}
	return normalizeSecret(data)
}

func readBoundedFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %q: %w", path, err)
	}
	info, statErr := file.Stat()
	if statErr != nil {
		_ = file.Close()
		return nil, fmt.Errorf("inspect %q: %w", path, statErr)
	}
	if !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, fmt.Errorf("read %q: not a regular file", path)
	}
	data, readErr := io.ReadAll(io.LimitReader(file, maxSecretBytes+1))
	closeErr := file.Close()
	if readErr != nil {
		return nil, fmt.Errorf("read %q: %w", path, readErr)
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close %q: %w", path, closeErr)
	}
	if len(data) > maxSecretBytes {
		return nil, fmt.Errorf("read %q: file exceeds %d bytes", path, maxSecretBytes)
	}
	return data, nil
}

func normalizeSecret(data []byte) (string, error) {
	if len(data) > maxSecretBytes {
		return "", fmt.Errorf("value exceeds %d bytes", maxSecretBytes)
	}
	if bytes.HasSuffix(data, []byte("\r\n")) {
		data = data[:len(data)-2]
	} else if bytes.HasSuffix(data, []byte("\n")) {
		data = data[:len(data)-1]
	}
	return validateSecret(data)
}

func validateSecret(data []byte) (string, error) {
	if len(data) > maxSecretBytes {
		return "", fmt.Errorf("value exceeds %d bytes", maxSecretBytes)
	}
	if len(data) == 0 {
		return "", fmt.Errorf("value is empty")
	}
	if !utf8.Valid(data) {
		return "", fmt.Errorf("value is not valid UTF-8")
	}
	for _, value := range data {
		if value < ' ' || value == 0x7f {
			return "", fmt.Errorf("value contains a control character")
		}
	}
	return string(data), nil
}
