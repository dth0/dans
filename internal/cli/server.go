package cli

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"time"

	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/httpserver"
	"github.com/ncode/dans/internal/ratelimit"
	"github.com/ncode/dans/internal/upstream"
	"github.com/spf13/cobra"
)

const (
	maxServeDuration      = 24 * time.Hour
	maxRateLimitTimeout   = time.Second
	maxRateLimitPolicyLen = 4 << 20
)

// ServeConfig is the immutable, secret-aware runtime configuration passed to
// the production server after Viper and every secret source have been read.
type ServeConfig struct {
	Address                       string
	DevelopmentHTTP               bool
	DatabaseURL                   httpapi.Secret
	DatabaseMaxConnections        int32
	DatabaseAuthenticationReserve int32
	DatabaseReadinessReserve      int32
	DatabaseConnectTimeout        time.Duration
	DatabaseStatementTimeout      time.Duration
	DatabaseLockTimeout           time.Duration
	DatabaseTransactionTimeout    time.Duration
	PowerDNSURL                   string
	PowerDNSUnixSocket            string
	PowerDNSUpstream              string
	PowerDNSAPIKey                httpapi.Secret
	PowerDNSTimeout               time.Duration
	MaxBodyBytes                  int64
	RequestTimeout                time.Duration
	MaxConcurrentRequests         int
	MaxHeaderBytes                int
	ReadHeaderTimeout             time.Duration
	ReadTimeout                   time.Duration
	WriteTimeout                  time.Duration
	IdleTimeout                   time.Duration
	HealthTimeout                 time.Duration
	ShutdownTimeout               time.Duration
	RateLimitEnabled              bool
	RateLimitRedisTimeout         time.Duration
	// RedisURL, RateLimitPolicy, and RateLimitWarnings are resolved only when
	// rate limiting is enabled.
	RedisURL          httpapi.Secret
	RateLimitPolicy   *ratelimit.Table
	RateLimitWarnings []string
}

// Server owns the long-running API runtime for the serve command.
type Server interface {
	Serve(context.Context, ServeConfig) error
}

func newServeCommand(options Options) *cobra.Command {
	return &cobra.Command{
		Use:   "serve",
		Short: "Serve the DANS API",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			config, err := loadConfig(cmd, configScopeServe)
			if err != nil {
				return invocationFailure(err)
			}
			databaseURL, err := loadDatabaseURL(config)
			if err != nil {
				return invocationFailure(err)
			}
			powerDNSAPIKey, err := loadPowerDNSAPIKey(config)
			if err != nil {
				return invocationFailure(err)
			}
			serveConfig, err := config.newServeConfig(databaseURL, powerDNSAPIKey)
			if err != nil {
				return invocationFailure(err)
			}
			if serveConfig.RateLimitEnabled {
				if serveConfig.RedisURL, err = loadRedisURL(config); err != nil {
					return invocationFailure(err)
				}
				if serveConfig.RateLimitPolicy, serveConfig.RateLimitWarnings, err = loadRateLimitPolicy(config.RateLimitPolicyFile); err != nil {
					return invocationFailure(err)
				}
			}
			if options.Server == nil {
				return serveFailure(errors.New("server runtime is not available"), databaseURL, powerDNSAPIKey, serveConfig.RedisURL)
			}
			if err := options.Server.Serve(cmd.Context(), serveConfig); err != nil {
				return serveFailure(err, databaseURL, powerDNSAPIKey, serveConfig.RedisURL)
			}
			return nil
		},
	}
}

func (config Config) newServeConfig(databaseURL, powerDNSAPIKey httpapi.Secret) (ServeConfig, error) {
	serveConfig, err := config.serveLimits()
	if err != nil {
		return ServeConfig{}, err
	}
	serveConfig.DatabaseURL = databaseURL
	serveConfig.PowerDNSAPIKey = powerDNSAPIKey
	return serveConfig, nil
}

func (config Config) serveLimits() (ServeConfig, error) {
	var result ServeConfig
	var err error
	result.Address = config.Listen
	switch config.BrowserCookieMode {
	case "secure":
	case "development-http":
		result.DevelopmentHTTP = true
	default:
		return ServeConfig{}, errors.New("validate config: browser_cookie_mode must be secure or development-http")
	}
	result.PowerDNSURL = config.PowerDNSURL
	result.PowerDNSUnixSocket = config.PowerDNSUnixSocket
	result.PowerDNSUpstream = config.PowerDNSUpstream
	if result.PowerDNSTimeout, err = durationSetting("powerdns_timeout", config.PowerDNSTimeout); err != nil {
		return ServeConfig{}, err
	}
	if result.DatabaseMaxConnections, err = int32Setting("database_max_connections", config.DatabaseMaxConnections, 3, 1_000); err != nil {
		return ServeConfig{}, err
	}
	if result.DatabaseAuthenticationReserve, err = int32Setting("database_authentication_reserve", config.DatabaseAuthenticationReserve, 1, 999); err != nil {
		return ServeConfig{}, err
	}
	if result.DatabaseReadinessReserve, err = int32Setting("database_readiness_reserve", config.DatabaseReadinessReserve, 1, 999); err != nil {
		return ServeConfig{}, err
	}
	if result.DatabaseMaxConnections <= result.DatabaseAuthenticationReserve+result.DatabaseReadinessReserve {
		return ServeConfig{}, fmt.Errorf("validate config: database_max_connections must include request, authentication, and readiness capacity")
	}
	for _, setting := range []struct {
		name   string
		value  string
		target *time.Duration
	}{
		{name: "database_connect_timeout", value: config.DatabaseConnectTimeout, target: &result.DatabaseConnectTimeout},
		{name: "database_statement_timeout", value: config.DatabaseStatementTimeout, target: &result.DatabaseStatementTimeout},
		{name: "database_lock_timeout", value: config.DatabaseLockTimeout, target: &result.DatabaseLockTimeout},
		{name: "database_transaction_timeout", value: config.DatabaseTransactionTimeout, target: &result.DatabaseTransactionTimeout},
		{name: "request_timeout", value: config.RequestTimeout, target: &result.RequestTimeout},
		{name: "read_header_timeout", value: config.ReadHeaderTimeout, target: &result.ReadHeaderTimeout},
		{name: "read_timeout", value: config.ReadTimeout, target: &result.ReadTimeout},
		{name: "write_timeout", value: config.WriteTimeout, target: &result.WriteTimeout},
		{name: "idle_timeout", value: config.IdleTimeout, target: &result.IdleTimeout},
		{name: "health_timeout", value: config.HealthTimeout, target: &result.HealthTimeout},
		{name: "shutdown_timeout", value: config.ShutdownTimeout, target: &result.ShutdownTimeout},
	} {
		*setting.target, err = durationSetting(setting.name, setting.value)
		if err != nil {
			return ServeConfig{}, err
		}
	}
	if result.MaxBodyBytes, err = int64Setting("max_body_bytes", config.MaxBodyBytes, 1, 64<<20); err != nil {
		return ServeConfig{}, err
	}
	maxConcurrent, err := int64Setting("max_concurrent_requests", config.MaxConcurrentRequests, 1, 100_000)
	if err != nil {
		return ServeConfig{}, err
	}
	result.MaxConcurrentRequests = int(maxConcurrent)
	maxHeaderBytes, err := int64Setting("max_header_bytes", config.MaxHeaderBytes, 1, 16<<20)
	if err != nil {
		return ServeConfig{}, err
	}
	result.MaxHeaderBytes = int(maxHeaderBytes)
	switch config.RateLimitEnabled {
	case "true":
		result.RateLimitEnabled = true
	case "false":
	default:
		return ServeConfig{}, errors.New("validate config: rate_limit_enabled must be true or false")
	}
	timeout, err := time.ParseDuration(config.RateLimitRedisTimeout)
	if err != nil || timeout < time.Millisecond || timeout > maxRateLimitTimeout {
		return ServeConfig{}, errors.New("validate config: rate_limit_redis_timeout must be a duration from 1ms through 1s")
	}
	result.RateLimitRedisTimeout = timeout

	client, _, err := upstream.NewHTTPClient(upstream.TransportConfig{
		URL: result.PowerDNSURL, UnixSocket: result.PowerDNSUnixSocket, Timeout: result.PowerDNSTimeout,
	})
	if err != nil {
		return ServeConfig{}, fmt.Errorf("validate config: %w", err)
	}
	client.CloseIdleConnections()
	return result, nil
}

func durationSetting(name, value string) (time.Duration, error) {
	duration, err := time.ParseDuration(value)
	if err != nil || duration < time.Millisecond || duration > maxServeDuration {
		return 0, fmt.Errorf("validate config: %s must be a duration from 1ms through 24h", name)
	}
	return duration, nil
}

func int32Setting(name, value string, minimum, maximum int64) (int32, error) {
	parsed, err := int64Setting(name, value, minimum, maximum)
	return int32(parsed), err
}

func int64Setting(name, value string, minimum, maximum int64) (int64, error) {
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed < minimum || parsed > maximum {
		return 0, fmt.Errorf("validate config: %s must be an integer from %d through %d", name, minimum, maximum)
	}
	return parsed, nil
}

// loadRateLimitPolicy reads the optional policy file once. Without a file,
// every identity uses the built-in Route 53-derived defaults.
func loadRateLimitPolicy(path string) (*ratelimit.Table, []string, error) {
	if path == "" {
		return ratelimit.NewBuiltinTable(), nil, nil
	}
	data, err := readBoundedConfigFile(path, maxRateLimitPolicyLen)
	if err != nil {
		return nil, nil, fmt.Errorf("load rate-limit policy: %w", err)
	}
	operations, err := httpserver.ContractOperationIDs()
	if err != nil {
		return nil, nil, fmt.Errorf("load rate-limit policy: %w", err)
	}
	table, warnings, err := ratelimit.ParsePolicy(data, operations)
	if err != nil {
		return nil, nil, fmt.Errorf("load rate-limit policy %q: %w", path, err)
	}
	return table, warnings, nil
}

func serveFailure(err error, databaseURL, powerDNSAPIKey httpapi.Secret, others ...httpapi.Secret) error {
	secrets := append([]httpapi.Secret{databaseURL, powerDNSAPIKey}, others...)
	for _, connection := range append([]httpapi.Secret{databaseURL}, others...) {
		if parsed, parseErr := url.Parse(connection.Value()); parseErr == nil && parsed.User != nil {
			if password, ok := parsed.User.Password(); ok && password != "" {
				secrets = append(secrets, httpapi.NewSecret(password))
			}
		}
	}
	return &serveRuntimeError{err: runtimeFailure(fmt.Errorf("serve DANS API: %w", &redactedCause{
		cause: err, message: httpapi.RedactText(err.Error(), secrets...),
	}))}
}

type serveRuntimeError struct{ err error }

func (err *serveRuntimeError) Error() string { return err.err.Error() }

func (err *serveRuntimeError) Unwrap() error { return err.err }
