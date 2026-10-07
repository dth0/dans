package cli

import (
	"bytes"
	"context"
	"log/slog"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/ratelimit"
)

func TestDisabledRateLimitingCreatesNoClient(t *testing.T) {
	logs := new(bytes.Buffer)
	limiter, closeLimiter, err := newRateLimiter(validRuntimeServeConfig(), slog.New(slog.NewJSONHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer closeLimiter()
	if limiter != nil {
		t.Fatalf("disabled rate limiting built limiter %T", limiter)
	}
	if logs.Len() != 0 {
		t.Fatalf("disabled rate limiting logged: %s", logs)
	}
}

func TestUnreachableRedisFailsOpenWithinTimeout(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	_ = listener.Close()

	config := validRuntimeServeConfig()
	config.RateLimitEnabled = true
	config.RateLimitRedisTimeout = 20 * time.Millisecond
	config.RedisURL = httpapi.NewSecret("redis://:redis-secret@" + address + "/0")
	config.RateLimitPolicy = ratelimit.NewBuiltinTable()
	config.RateLimitWarnings = []string{"rate-limit defaults: change capacity 10 is below 200"}
	logs := new(bytes.Buffer)

	started := time.Now()
	limiter, closeLimiter, err := newRateLimiter(config, slog.New(slog.NewJSONHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer closeLimiter()
	if time.Since(started) > 100*time.Millisecond {
		t.Fatal("limiter construction waited for Redis")
	}

	started = time.Now()
	decision := limiter.Admit(context.Background(), ratelimit.Request{IdentityID: "00000000-0000-4000-8000-000000000001", Operation: "listZones"})
	if decision.Outcome != ratelimit.OutcomeUnmetered {
		t.Fatalf("outcome = %s, want unmetered", decision.Outcome)
	}
	if waited := time.Since(started); waited > 500*time.Millisecond {
		t.Fatalf("unreachable Redis delayed the request %s", waited)
	}
	for _, want := range []string{`"event":"rate_limit.policy_warning"`, `"event":"rate_limit.fail_open"`} {
		if !strings.Contains(logs.String(), want) {
			t.Fatalf("logs lack %s: %s", want, logs)
		}
	}
	if strings.Contains(logs.String(), "redis-secret") || strings.Contains(logs.String(), address) {
		t.Fatalf("logs expose the Redis URL: %s", logs)
	}
}

func TestEnabledRateLimitingRequiresResolvedPolicy(t *testing.T) {
	config := validRuntimeServeConfig()
	config.RateLimitEnabled = true
	config.RateLimitRedisTimeout = 20 * time.Millisecond
	config.RedisURL = httpapi.NewSecret("redis://127.0.0.1:1/0")
	if _, _, err := newRateLimiter(config, slog.New(slog.DiscardHandler)); err == nil {
		t.Fatal("enabled rate limiting without a policy succeeded")
	}
}
