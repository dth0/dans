package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"

	"github.com/ncode/dans/internal/httpapi"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

const (
	defaultEndpoint                      = "http://127.0.0.1:8080/api/v1"
	defaultListen                        = "127.0.0.1:8080"
	defaultPowerDNSUpstream              = "default"
	defaultPowerDNSTimeout               = "20s"
	defaultDatabaseMaxConnections        = "12"
	defaultDatabaseAuthenticationReserve = "2"
	defaultDatabaseReadinessReserve      = "1"
	defaultDatabaseConnectTimeout        = "5s"
	defaultDatabaseStatementTimeout      = "10s"
	defaultDatabaseLockTimeout           = "2s"
	defaultDatabaseTransactionTimeout    = "15s"
	defaultMaxBodyBytes                  = "16777216"
	defaultRequestTimeout                = "30s"
	defaultMaxConcurrentRequests         = "64"
	defaultMaxHeaderBytes                = "1048576"
	defaultReadHeaderTimeout             = "5s"
	defaultReadTimeout                   = "35s"
	defaultWriteTimeout                  = "35s"
	defaultIdleTimeout                   = "60s"
	defaultHealthTimeout                 = "5s"
	defaultShutdownTimeout               = "30s"
	defaultRateLimitEnabled              = "false"
	defaultRateLimitRedisTimeout         = "25ms"
	maxConfigBytes                       = 1 << 20
)

type configScope uint8

const (
	configScopeOnline configScope = iota + 1
	configScopeDatabase
	configScopeServe
)

// Config is the immutable configuration resolved for one command invocation.
type Config struct {
	Endpoint                      string `mapstructure:"endpoint" json:"endpoint"`
	Output                        string `mapstructure:"output" json:"output"`
	Listen                        string `mapstructure:"listen" json:"listen"`
	BrowserCookieMode             string `mapstructure:"browser_cookie_mode" json:"browser_cookie_mode"`
	APITokenFile                  string `mapstructure:"api_token_file" json:"api_token_file"`
	DatabaseURLFile               string `mapstructure:"database_url_file" json:"database_url_file"`
	PowerDNSURL                   string `mapstructure:"powerdns_url" json:"powerdns_url"`
	PowerDNSUnixSocket            string `mapstructure:"powerdns_unix_socket" json:"powerdns_unix_socket"`
	PowerDNSUpstream              string `mapstructure:"powerdns_upstream" json:"powerdns_upstream"`
	PowerDNSTimeout               string `mapstructure:"powerdns_timeout" json:"powerdns_timeout"`
	PowerDNSAPIKeyFile            string `mapstructure:"powerdns_api_key_file" json:"powerdns_api_key_file"`
	PowerDNSConfigFile            string `mapstructure:"powerdns_config_file" json:"powerdns_config_file"`
	DatabaseMaxConnections        string `mapstructure:"database_max_connections" json:"database_max_connections"`
	DatabaseAuthenticationReserve string `mapstructure:"database_authentication_reserve" json:"database_authentication_reserve"`
	DatabaseReadinessReserve      string `mapstructure:"database_readiness_reserve" json:"database_readiness_reserve"`
	DatabaseConnectTimeout        string `mapstructure:"database_connect_timeout" json:"database_connect_timeout"`
	DatabaseStatementTimeout      string `mapstructure:"database_statement_timeout" json:"database_statement_timeout"`
	DatabaseLockTimeout           string `mapstructure:"database_lock_timeout" json:"database_lock_timeout"`
	DatabaseTransactionTimeout    string `mapstructure:"database_transaction_timeout" json:"database_transaction_timeout"`
	MaxBodyBytes                  string `mapstructure:"max_body_bytes" json:"max_body_bytes"`
	RequestTimeout                string `mapstructure:"request_timeout" json:"request_timeout"`
	MaxConcurrentRequests         string `mapstructure:"max_concurrent_requests" json:"max_concurrent_requests"`
	MaxHeaderBytes                string `mapstructure:"max_header_bytes" json:"max_header_bytes"`
	ReadHeaderTimeout             string `mapstructure:"read_header_timeout" json:"read_header_timeout"`
	ReadTimeout                   string `mapstructure:"read_timeout" json:"read_timeout"`
	WriteTimeout                  string `mapstructure:"write_timeout" json:"write_timeout"`
	IdleTimeout                   string `mapstructure:"idle_timeout" json:"idle_timeout"`
	HealthTimeout                 string `mapstructure:"health_timeout" json:"health_timeout"`
	ShutdownTimeout               string `mapstructure:"shutdown_timeout" json:"shutdown_timeout"`
	RateLimitEnabled              string `mapstructure:"rate_limit_enabled" json:"rate_limit_enabled"`
	RateLimitRedisTimeout         string `mapstructure:"rate_limit_redis_timeout" json:"rate_limit_redis_timeout"`
	RateLimitPolicyFile           string `mapstructure:"rate_limit_policy_file" json:"rate_limit_policy_file"`
	RedisURLFile                  string `mapstructure:"redis_url_file" json:"redis_url_file"`
}

var configBindings = []struct {
	key  string
	flag string
	env  string
}{
	{key: "endpoint", flag: "endpoint", env: "DANS_ENDPOINT"},
	{key: "output", flag: "output", env: "DANS_OUTPUT"},
	{key: "listen", flag: "listen", env: "DANS_LISTEN"},
	{key: "browser_cookie_mode", flag: "browser-cookie-mode", env: "DANS_BROWSER_COOKIE_MODE"},
	{key: "api_token_file", flag: "api-token-file", env: "DANS_API_TOKEN_FILE"},
	{key: "database_url_file", flag: "database-url-file", env: "DANS_DATABASE_URL_FILE"},
	{key: "powerdns_url", flag: "powerdns-url", env: "DANS_POWERDNS_URL"},
	{key: "powerdns_unix_socket", flag: "powerdns-unix-socket", env: "DANS_POWERDNS_UNIX_SOCKET"},
	{key: "powerdns_upstream", flag: "powerdns-upstream", env: "DANS_POWERDNS_UPSTREAM"},
	{key: "powerdns_timeout", flag: "powerdns-timeout", env: "DANS_POWERDNS_TIMEOUT"},
	{key: "powerdns_api_key_file", flag: "powerdns-api-key-file", env: "DANS_POWERDNS_API_KEY_FILE"},
	{key: "powerdns_config_file", flag: "powerdns-config-file", env: "DANS_POWERDNS_CONFIG_FILE"},
	{key: "database_max_connections", flag: "database-max-connections", env: "DANS_DATABASE_MAX_CONNECTIONS"},
	{key: "database_authentication_reserve", flag: "database-authentication-reserve", env: "DANS_DATABASE_AUTHENTICATION_RESERVE"},
	{key: "database_readiness_reserve", flag: "database-readiness-reserve", env: "DANS_DATABASE_READINESS_RESERVE"},
	{key: "database_connect_timeout", flag: "database-connect-timeout", env: "DANS_DATABASE_CONNECT_TIMEOUT"},
	{key: "database_statement_timeout", flag: "database-statement-timeout", env: "DANS_DATABASE_STATEMENT_TIMEOUT"},
	{key: "database_lock_timeout", flag: "database-lock-timeout", env: "DANS_DATABASE_LOCK_TIMEOUT"},
	{key: "database_transaction_timeout", flag: "database-transaction-timeout", env: "DANS_DATABASE_TRANSACTION_TIMEOUT"},
	{key: "max_body_bytes", flag: "max-body-bytes", env: "DANS_MAX_BODY_BYTES"},
	{key: "request_timeout", flag: "request-timeout", env: "DANS_REQUEST_TIMEOUT"},
	{key: "max_concurrent_requests", flag: "max-concurrent-requests", env: "DANS_MAX_CONCURRENT_REQUESTS"},
	{key: "max_header_bytes", flag: "max-header-bytes", env: "DANS_MAX_HEADER_BYTES"},
	{key: "read_header_timeout", flag: "read-header-timeout", env: "DANS_READ_HEADER_TIMEOUT"},
	{key: "read_timeout", flag: "read-timeout", env: "DANS_READ_TIMEOUT"},
	{key: "write_timeout", flag: "write-timeout", env: "DANS_WRITE_TIMEOUT"},
	{key: "idle_timeout", flag: "idle-timeout", env: "DANS_IDLE_TIMEOUT"},
	{key: "health_timeout", flag: "health-timeout", env: "DANS_HEALTH_TIMEOUT"},
	{key: "shutdown_timeout", flag: "shutdown-timeout", env: "DANS_SHUTDOWN_TIMEOUT"},
	{key: "rate_limit_enabled", flag: "rate-limit-enabled", env: "DANS_RATE_LIMIT_ENABLED"},
	{key: "rate_limit_redis_timeout", flag: "rate-limit-redis-timeout", env: "DANS_RATE_LIMIT_REDIS_TIMEOUT"},
	{key: "rate_limit_policy_file", flag: "rate-limit-policy-file", env: "DANS_RATE_LIMIT_POLICY_FILE"},
	{key: "redis_url_file", flag: "redis-url-file", env: "DANS_REDIS_URL_FILE"},
}

func addConfigFlags(root *cobra.Command) {
	flags := root.PersistentFlags()
	flags.String("config", "", "JSON configuration file (or DANS_CONFIG)")
	flags.String("endpoint", "", "DANS API endpoint")
	flags.String("output", "", "Output format: text or json")
	flags.String("listen", "", "HTTP listen address")
	flags.String("browser-cookie-mode", "", "Browser cookies: secure (default) or development-http (local development only)")
	flags.String("api-token-file", "", "File containing the DANS API token")
	flags.String("database-url-file", "", "File containing the PostgreSQL URL")
	flags.String("powerdns-url", "", "PowerDNS API endpoint")
	flags.String("powerdns-unix-socket", "", "Absolute PowerDNS API Unix socket path")
	flags.String("powerdns-upstream", "", "Stable PowerDNS upstream identifier")
	flags.String("powerdns-timeout", "", "PowerDNS request timeout")
	flags.String("powerdns-api-key-file", "", "File containing the PowerDNS API key")
	flags.String("powerdns-config-file", "", "Rendered PowerDNS configuration fragment")
	flags.String("database-max-connections", "", "Maximum PostgreSQL connections per instance")
	flags.String("database-authentication-reserve", "", "PostgreSQL connections reserved for authentication")
	flags.String("database-readiness-reserve", "", "PostgreSQL connections reserved for readiness")
	flags.String("database-connect-timeout", "", "PostgreSQL connection timeout")
	flags.String("database-statement-timeout", "", "PostgreSQL statement timeout")
	flags.String("database-lock-timeout", "", "PostgreSQL lock timeout")
	flags.String("database-transaction-timeout", "", "PostgreSQL idle transaction timeout")
	flags.String("max-body-bytes", "", "Maximum HTTP request body size")
	flags.String("request-timeout", "", "HTTP request deadline")
	flags.String("max-concurrent-requests", "", "Maximum concurrent HTTP requests")
	flags.String("max-header-bytes", "", "Maximum HTTP request header size")
	flags.String("read-header-timeout", "", "HTTP header read timeout")
	flags.String("read-timeout", "", "HTTP request read timeout")
	flags.String("write-timeout", "", "HTTP response write timeout")
	flags.String("idle-timeout", "", "HTTP keep-alive idle timeout")
	flags.String("health-timeout", "", "Readiness dependency timeout")
	flags.String("shutdown-timeout", "", "Graceful shutdown deadline")
	flags.String("rate-limit-enabled", "", "Meter identities with shared token buckets: true or false (default false)")
	flags.String("rate-limit-redis-timeout", "", "Rate-limit Redis timeout before failing open (1ms through 1s)")
	flags.String("rate-limit-policy-file", "", "JSON rate-limit policy with defaults and per-identity overrides")
	flags.String("redis-url-file", "", "File containing the rate-limit Redis URL")
}

func loadConfig(cmd *cobra.Command, scope configScope) (Config, error) {
	v := viper.New()
	v.SetDefault("endpoint", defaultEndpoint)
	v.SetDefault("output", "text")
	v.SetDefault("listen", defaultListen)
	v.SetDefault("browser_cookie_mode", "secure")
	v.SetDefault("powerdns_upstream", defaultPowerDNSUpstream)
	v.SetDefault("powerdns_timeout", defaultPowerDNSTimeout)
	v.SetDefault("database_max_connections", defaultDatabaseMaxConnections)
	v.SetDefault("database_authentication_reserve", defaultDatabaseAuthenticationReserve)
	v.SetDefault("database_readiness_reserve", defaultDatabaseReadinessReserve)
	v.SetDefault("database_connect_timeout", defaultDatabaseConnectTimeout)
	v.SetDefault("database_statement_timeout", defaultDatabaseStatementTimeout)
	v.SetDefault("database_lock_timeout", defaultDatabaseLockTimeout)
	v.SetDefault("database_transaction_timeout", defaultDatabaseTransactionTimeout)
	v.SetDefault("max_body_bytes", defaultMaxBodyBytes)
	v.SetDefault("request_timeout", defaultRequestTimeout)
	v.SetDefault("max_concurrent_requests", defaultMaxConcurrentRequests)
	v.SetDefault("max_header_bytes", defaultMaxHeaderBytes)
	v.SetDefault("read_header_timeout", defaultReadHeaderTimeout)
	v.SetDefault("read_timeout", defaultReadTimeout)
	v.SetDefault("write_timeout", defaultWriteTimeout)
	v.SetDefault("idle_timeout", defaultIdleTimeout)
	v.SetDefault("health_timeout", defaultHealthTimeout)
	v.SetDefault("shutdown_timeout", defaultShutdownTimeout)
	v.SetDefault("rate_limit_enabled", defaultRateLimitEnabled)
	v.SetDefault("rate_limit_redis_timeout", defaultRateLimitRedisTimeout)

	configPath, err := selectedConfigPath(cmd)
	if err != nil {
		return Config{}, err
	}
	if configPath != "" {
		values, err := readStrictConfig(configPath)
		if err != nil {
			return Config{}, err
		}
		if err := v.MergeConfigMap(values); err != nil {
			return Config{}, fmt.Errorf("load config %q: %w", configPath, err)
		}
	}

	for _, binding := range configBindings {
		if err := v.BindEnv(binding.key, binding.env); err != nil {
			return Config{}, fmt.Errorf("bind environment %s: %w", binding.env, err)
		}
		flag := cmd.Flags().Lookup(binding.flag)
		if flag == nil {
			return Config{}, fmt.Errorf("bind flag --%s: flag is not defined", binding.flag)
		}
		if err := v.BindPFlag(binding.key, flag); err != nil {
			return Config{}, fmt.Errorf("bind flag --%s: %w", binding.flag, err)
		}
	}

	var config Config
	if err := v.UnmarshalExact(&config); err != nil {
		return Config{}, fmt.Errorf("decode config: %w", err)
	}
	if err := config.validate(scope); err != nil {
		return Config{}, err
	}
	return config, nil
}

func selectedConfigPath(cmd *cobra.Command) (string, error) {
	flag := cmd.Flags().Lookup("config")
	if flag == nil {
		return "", fmt.Errorf("read --config: flag is not defined")
	}
	if flag.Changed {
		return flag.Value.String(), nil
	}
	if value, ok := os.LookupEnv("DANS_CONFIG"); ok && value != "" {
		return value, nil
	}
	return "", nil
}

func readStrictConfig(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %q: %w", path, err)
	}
	if err := httpapi.StrictJSON(bytes.NewReader(data), maxConfigBytes, func(Config) error { return nil }); err != nil {
		return nil, fmt.Errorf("decode config %q as strict JSON: %w", path, err)
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	var raw map[string]json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return nil, fmt.Errorf("decode config %q as JSON: %w", path, err)
	}
	if raw == nil {
		return nil, fmt.Errorf("decode config %q as JSON: expected object", path)
	}
	if err := requireJSONEOF(decoder); err != nil {
		return nil, fmt.Errorf("decode config %q as JSON: %w", path, err)
	}

	allowed := make(map[string]struct{}, len(configBindings))
	for _, binding := range configBindings {
		allowed[binding.key] = struct{}{}
	}
	values := make(map[string]any, len(raw))
	for key, value := range raw {
		if _, ok := allowed[key]; !ok {
			return nil, fmt.Errorf("decode config %q as JSON: unknown property %q", path, key)
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, fmt.Errorf("decode config %q as JSON: property %q must be a string", path, key)
		}
		var text string
		if err := json.Unmarshal(value, &text); err != nil {
			return nil, fmt.Errorf("decode config %q as JSON: property %q must be a string", path, key)
		}
		values[key] = text
	}
	return values, nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("unexpected trailing JSON value")
		}
		return err
	}
	return nil
}

func (config Config) validate(scope configScope) error {
	if config.Output != "text" && config.Output != "json" {
		return fmt.Errorf("validate config: output must be text or json")
	}
	switch scope {
	case configScopeOnline:
		parsed, err := url.Parse(config.Endpoint)
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return fmt.Errorf("validate config: endpoint must be an absolute HTTP URL")
		}
		if parsed.Scheme != "http" && parsed.Scheme != "https" {
			return fmt.Errorf("validate config: endpoint must use HTTP or HTTPS")
		}
		if _, err := durationSetting("request_timeout", config.RequestTimeout); err != nil {
			return err
		}
	case configScopeDatabase:
		// The required URL is a secret and is validated after resolving its
		// mutually exclusive environment or file source.
	case configScopeServe:
		if strings.TrimSpace(config.Listen) == "" {
			return fmt.Errorf("validate config: listen is required")
		}
		if (strings.TrimSpace(config.PowerDNSURL) == "") == (strings.TrimSpace(config.PowerDNSUnixSocket) == "") {
			return fmt.Errorf("validate config: exactly one of powerdns_url or powerdns_unix_socket is required")
		}
		if strings.TrimSpace(config.PowerDNSUpstream) == "" {
			return fmt.Errorf("validate config: powerdns_upstream is required")
		}
		if _, err := config.serveLimits(); err != nil {
			return err
		}
	default:
		return fmt.Errorf("validate config: unknown command scope")
	}
	return nil
}
