package ratelimit

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"math"
	"net"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestParseTakeReply(t *testing.T) {
	admitted, err := parseTakeReply([]int64{0}, 2)
	if err != nil || !admitted.Admitted {
		t.Fatalf("admitted reply = %+v, %v", admitted, err)
	}
	throttled, err := parseTakeReply([]int64{1, 1500, 0, 2}, 3)
	if err != nil || throttled.Admitted || throttled.Wait != 1500*time.Millisecond || !slices.Equal(throttled.Short, []int{0, 2}) {
		t.Fatalf("throttled reply = %+v, %v", throttled, err)
	}
	for _, reply := range [][]int64{nil, {1, 10}, {1, 10, 3}, {1, 10, -1}, {1, -1, 0}, {1, math.MaxInt64/int64(time.Millisecond) + 1, 0}, {2, 0}, {9}} {
		if _, err := parseTakeReply(reply, 3); err == nil {
			t.Errorf("parseTakeReply(%v) succeeded", reply)
		}
	}
}

func TestNewRedisClientValidatesURLWithoutConnecting(t *testing.T) {
	client, err := NewRedisClient("redis://dans:password@127.0.0.1:1/0", 25*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if client.Timeout() != 25*time.Millisecond {
		t.Fatalf("timeout = %s", client.Timeout())
	}
	if stats := client.pool.Stats(); stats.ActiveCount != 0 || client.pool.MaxActive != redisMaxActive || !client.pool.Wait {
		t.Fatalf("pool = %+v (max active %d, wait %v), want lazy bounded waiting", stats, client.pool.MaxActive, client.pool.Wait)
	}
	for _, invalid := range []string{
		"postgres://localhost/dans", "localhost:6379", "redis://[::1", "redis:///0",
		"redis://localhost/not-a-db", "redis://localhost/-1", "redis://localhost/18446744073709551616",
		"redis://localhost:65536/0",
	} {
		if _, err := NewRedisClient(invalid, time.Millisecond); err == nil || strings.Contains(err.Error(), invalid) {
			t.Errorf("NewRedisClient(%q) error = %v, want a redacted validation error", invalid, err)
		}
	}
	if _, err := NewRedisClient("redis://127.0.0.1:1", 0); err == nil {
		t.Error("NewRedisClient accepted a zero timeout")
	}
}

func TestParseRedisURL(t *testing.T) {
	for _, suffix := range []string{
		"", "/", "/0", "/1", "/007", "/%31", "/" + strconv.Itoa(math.MaxInt),
		":1/0", ":6379/0", ":65535/0",
	} {
		for _, scheme := range []string{"redis", "rediss"} {
			rawURL := scheme + "://dans:password@localhost" + suffix
			t.Run(rawURL, func(t *testing.T) {
				if err := ParseRedisURL(rawURL); err != nil {
					t.Fatalf("valid URL rejected: %v", err)
				}
			})
		}
	}
	for _, rawURL := range []string{"redis://[::1]:6379/0", "rediss://[::1]:65535/1"} {
		if err := ParseRedisURL(rawURL); err != nil {
			t.Errorf("valid IPv6 URL rejected: %v", err)
		}
	}
	for _, suffix := range []string{
		"/not-a-db", "/-1", "/+1", "/1.5", "/1/2", "/1/", "/%2B1",
		"/18446744073709551616", ":0/0", ":65536/0", ":18446744073709551616/0", ":not-a-port/0",
	} {
		for _, scheme := range []string{"redis", "rediss"} {
			rawURL := scheme + "://dans:redis-secret@redis.internal" + suffix
			t.Run(rawURL, func(t *testing.T) {
				err := ParseRedisURL(rawURL)
				if err == nil {
					t.Fatal("invalid URL accepted")
				}
				for _, secret := range []string{rawURL, "redis-secret", "redis.internal", suffix} {
					if strings.Contains(err.Error(), secret) {
						t.Fatalf("validation error exposed URL contents: %v", err)
					}
				}
			})
		}
	}
}

func TestRedisTLSHandshakeFailsOpenWithinTimeout(t *testing.T) {
	for _, test := range []struct {
		name           string
		clientTimeout  time.Duration
		limiterTimeout time.Duration
		cancelCaller   bool
	}{
		{name: "client timeout", clientTimeout: 25 * time.Millisecond, limiterTimeout: time.Second},
		{name: "limiter deadline", clientTimeout: time.Second, limiterTimeout: 25 * time.Millisecond},
		{name: "canceled caller", clientTimeout: time.Second, limiterTimeout: time.Second, cancelCaller: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			handshakeStarted := make(chan struct{})
			serverDone := make(chan struct{})
			go func() {
				defer close(serverDone)
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
				if _, err := io.ReadFull(conn, make([]byte, 1)); err != nil {
					return
				}
				close(handshakeStarted)
				if test.cancelCaller {
					cancel()
				}
				_, _ = io.Copy(io.Discard, conn)
			}()
			t.Cleanup(func() {
				_ = listener.Close()
				<-serverDone
			})

			client, err := NewRedisClient("rediss://"+listener.Addr().String(), test.clientTimeout)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = client.Close() })
			backend, err := NewRedisBackend(client)
			if err != nil {
				t.Fatal(err)
			}
			logs := new(bytes.Buffer)
			limiter, err := NewLimiter(LimiterConfig{
				Table: NewBuiltinTable(), Backend: backend, Timeout: test.limiterTimeout,
				Reporter: NewReporter(slog.New(slog.NewJSONHandler(logs, nil)), time.Second, nil),
			})
			if err != nil {
				t.Fatal(err)
			}
			started := time.Now()
			decision := limiter.Admit(ctx, Request{IdentityID: testIdentity, Operation: "listZones"})
			if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
				t.Errorf("stalled TLS handshake took %s, want prompt fail-open", elapsed)
			}
			if decision.Outcome != OutcomeUnmetered {
				t.Fatalf("outcome = %s, want unmetered", decision.Outcome)
			}
			select {
			case <-handshakeStarted:
			default:
				t.Fatal("client did not start the TLS handshake")
			}
			if test.cancelCaller {
				if logs.Len() != 0 {
					t.Errorf("canceled caller reported as backend failure: %s", logs)
				}
			} else if !strings.Contains(logs.String(), `"reason":"timeout"`) {
				t.Errorf("missing timeout warning: %s", logs)
			}
		})
	}
}

func TestTakeScriptFormatsLargeNumbersExplicitly(t *testing.T) {
	for _, required := range []string{"string.format('%.0f', watermarks[i])", "string.format('%.17g'", "redis.call('TIME')"} {
		if !strings.Contains(takeScriptSource, required) {
			t.Fatalf("script lacks %q", required)
		}
	}
}
