package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"time"

	"github.com/ncode/dans/internal/database"
	"github.com/ncode/dans/internal/httpserver"
	"github.com/ncode/dans/internal/ratelimit"
	"github.com/ncode/dans/internal/upstream"
	"github.com/ncode/dans/internal/webconsole"
)

// RuntimeServer assembles and owns one production API instance.
type RuntimeServer struct {
	logOutput io.Writer
}

// NewRuntimeServer creates a production server whose structured runtime and
// access logs are written to logOutput.
func NewRuntimeServer(logOutput io.Writer) *RuntimeServer {
	if logOutput == nil {
		logOutput = io.Discard
	}
	return &RuntimeServer{logOutput: logOutput}
}

func (runtime *RuntimeServer) Serve(ctx context.Context, config ServeConfig) error {
	if runtime == nil || ctx == nil {
		return errors.New("serve runtime: missing dependency")
	}
	configured := runtimeConfigurations(config)
	pools, err := database.OpenRuntimePools(ctx, configured.database)
	if err != nil {
		return fmt.Errorf("serve runtime: open PostgreSQL pools: %w", err)
	}
	defer pools.Close()

	store := database.NewStore(pools.Requests)
	authenticator := database.NewStore(pools.Authentication)
	readiness := database.NewStore(pools.Readiness)
	upstreamClient, err := upstream.New(configured.upstream, config.PowerDNSAPIKey)
	if err != nil {
		return fmt.Errorf("serve runtime: configure PowerDNS: %w", err)
	}
	auditHealth, err := httpserver.NewAuditHealth(readiness.ProbeAuditPersistence)
	if err != nil {
		return fmt.Errorf("serve runtime: configure audit health: %w", err)
	}
	powerDNSCompatibility := &httpserver.PowerDNSCompatibility{}
	workerCtx, stopWorkers := context.WithCancel(ctx)
	var workers sync.WaitGroup
	defer func() { stopWorkers(); workers.Wait() }()
	workers.Go(func() { runOverdueIntentCloser(workerCtx, store, auditHealth, time.Second) })
	browseTransport := configured.upstream
	browseTransport.Timeout = 5 * time.Minute
	browseClient, err := upstream.New(browseTransport, config.PowerDNSAPIKey)
	if err != nil {
		return fmt.Errorf("serve runtime: configure browsing: %w", err)
	}
	workers.Go(func() {
		for workerCtx.Err() == nil {
			if err := database.NewBrowseWorker(store, browseClient, config.PowerDNSUpstream, powerDNSCompatibility.Compatible).Run(workerCtx); err != nil && workerCtx.Err() == nil {
				slog.New(slog.NewJSONHandler(runtime.logOutput, nil)).Error("browsing worker stopped; retrying")
			}
			timer := time.NewTimer(time.Second)
			select {
			case <-workerCtx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	})
	schemaProbe := func(ctx context.Context) error {
		return database.CheckRuntimeCompatibility(ctx, pools.Readiness)
	}
	powerDNSProbe := func(ctx context.Context) error {
		err := upstreamClient.Probe(ctx)
		powerDNSCompatibility.Record(err)
		return err
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, config.HealthTimeout)
	_ = powerDNSProbe(probeCtx)
	cancelProbe()
	health, err := httpserver.NewHealth(httpserver.Dependencies{
		Database: pools.Readiness.Ping,
		Schema:   schemaProbe,
		Audit:    auditHealth.Probe,
		PowerDNS: powerDNSProbe,
	}, config.HealthTimeout)
	if err != nil {
		return fmt.Errorf("serve runtime: configure health: %w", err)
	}
	accessLogger := httpserver.NewJSONLogger(runtime.logOutput, slog.LevelInfo)
	rateLimiter, closeRateLimiter, err := newRateLimiter(config, accessLogger)
	if err != nil {
		return fmt.Errorf("serve runtime: configure rate limiting: %w", err)
	}
	defer closeRateLimiter()
	dans, err := httpserver.NewDANSOperations(httpserver.GeneratedConfig{
		Store:           store,
		Upstream:        upstreamClient,
		UpstreamID:      config.PowerDNSUpstream,
		MutationTimeout: config.PowerDNSTimeout,
		AuditFailures:   auditHealth,
	})
	if err != nil {
		return fmt.Errorf("serve runtime: configure generated handlers: %w", err)
	}
	handler, err := httpserver.NewApplicationHandler(httpserver.ApplicationConfig{
		Boundary:        configured.boundary,
		Logger:          accessLogger,
		Authenticator:   authenticator,
		BrowserSessions: &httpserver.BrowserSessions{Store: store, DevelopmentHTTP: config.DevelopmentHTTP},
		Schema: func(ctx context.Context) error {
			return database.CheckRuntimeCompatibility(ctx, pools.Requests)
		},
		PowerDNSReady:     powerDNSCompatibility.Compatible,
		Health:            health,
		Upstream:          upstreamClient,
		DANS:              dans,
		Mutations:         store,
		Lifecycle:         store,
		Denials:           store,
		AuditFailures:     auditHealth,
		LifecycleFailures: auditHealth,
		UpstreamID:        config.PowerDNSUpstream,
		MutationTimeout:   config.PowerDNSTimeout,
		RateLimiter:       rateLimiter,
	})
	if err != nil {
		return fmt.Errorf("serve runtime: configure HTTP application: %w", err)
	}
	httpServer, err := httpserver.NewHTTPServer(configured.server, webconsole.Alongside(handler))
	if err != nil {
		return fmt.Errorf("serve runtime: configure HTTP server: %w", err)
	}
	return httpserver.ListenAndServe(ctx, httpServer, health, config.ShutdownTimeout)
}

// newRateLimiter returns nil when rate limiting is disabled, so no Redis
// client exists and the middleware is not installed. When enabled, the client
// connects lazily: readiness never waits for or depends on Redis.
func newRateLimiter(config ServeConfig, logger *slog.Logger) (httpserver.RateLimiter, func(), error) {
	if !config.RateLimitEnabled {
		return nil, func() {}, nil
	}
	if config.RateLimitPolicy == nil {
		return nil, nil, errors.New("rate-limit policy is not resolved")
	}
	for _, warning := range config.RateLimitWarnings {
		logger.Warn("rate_limit.policy_warning", "event", "rate_limit.policy_warning", "warning", warning)
	}
	client, err := ratelimit.NewRedisClient(config.RedisURL.Value(), config.RateLimitRedisTimeout)
	if err != nil {
		return nil, nil, err
	}
	backend, err := ratelimit.NewRedisBackend(client)
	if err != nil {
		_ = client.Close()
		return nil, nil, err
	}
	limiter, err := ratelimit.NewLimiter(ratelimit.LimiterConfig{
		Table:    config.RateLimitPolicy,
		Backend:  backend,
		Timeout:  config.RateLimitRedisTimeout,
		Reporter: ratelimit.NewReporter(logger, ratelimit.DefaultWarningInterval, nil),
	})
	if err != nil {
		_ = client.Close()
		return nil, nil, err
	}
	return limiter, func() { _ = client.Close() }, nil
}

type overdueIntentCloser interface {
	CloseOverdueDNSIntents(context.Context, int) (int, error)
}

type auditFailureReporter interface {
	ReportAuditFailure()
}

func runOverdueIntentCloser(ctx context.Context, closer overdueIntentCloser, failures auditFailureReporter, interval time.Duration) {
	if closer == nil || failures == nil || interval <= 0 || ctx.Err() != nil {
		return
	}
	closeOverdue := func() {
		if _, err := closer.CloseOverdueDNSIntents(ctx, 100); err != nil && ctx.Err() == nil {
			failures.ReportAuditFailure()
		}
	}
	closeOverdue()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			closeOverdue()
		}
	}
}

type runtimeConfigurationSet struct {
	database database.RuntimePoolConfig
	boundary httpserver.BoundaryConfig
	server   httpserver.ServerConfig
	upstream upstream.TransportConfig
}

func runtimeConfigurations(config ServeConfig) runtimeConfigurationSet {
	return runtimeConfigurationSet{
		database: database.RuntimePoolConfig{
			ConnectionString:      config.DatabaseURL.Value(),
			MaxConnections:        config.DatabaseMaxConnections,
			AuthenticationReserve: config.DatabaseAuthenticationReserve,
			ReadinessReserve:      config.DatabaseReadinessReserve,
			ConnectTimeout:        config.DatabaseConnectTimeout,
			StatementTimeout:      config.DatabaseStatementTimeout,
			LockTimeout:           config.DatabaseLockTimeout,
			TransactionTimeout:    config.DatabaseTransactionTimeout,
		},
		boundary: httpserver.BoundaryConfig{
			MaxBodyBytes:   config.MaxBodyBytes,
			RequestTimeout: config.RequestTimeout,
			MaxConcurrent:  config.MaxConcurrentRequests,
		},
		server: httpserver.ServerConfig{
			Address:           config.Address,
			MaxHeaderBytes:    config.MaxHeaderBytes,
			ReadHeaderTimeout: config.ReadHeaderTimeout,
			ReadTimeout:       config.ReadTimeout,
			WriteTimeout:      config.WriteTimeout,
			IdleTimeout:       config.IdleTimeout,
		},
		upstream: upstream.TransportConfig{
			URL:        config.PowerDNSURL,
			UnixSocket: config.PowerDNSUnixSocket,
			Timeout:    config.PowerDNSTimeout,
		},
	}
}

var _ Server = (*RuntimeServer)(nil)
