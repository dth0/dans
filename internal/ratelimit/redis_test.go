package ratelimit

import (
	"slices"
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
	for _, reply := range [][]int64{nil, {1, 10}, {1, 10, 3}, {1, 10, -1}, {2, 0}, {9}} {
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
	for _, invalid := range []string{"postgres://localhost/dans", "localhost:6379", "redis://[::1", "redis:///0"} {
		if _, err := NewRedisClient(invalid, time.Millisecond); err == nil || strings.Contains(err.Error(), invalid) {
			t.Errorf("NewRedisClient(%q) error = %v, want a redacted validation error", invalid, err)
		}
	}
	if _, err := NewRedisClient("redis://127.0.0.1:1", 0); err == nil {
		t.Error("NewRedisClient accepted a zero timeout")
	}
}

func TestTakeScriptFormatsLargeNumbersExplicitly(t *testing.T) {
	for _, required := range []string{"string.format('%.0f', now_us)", "string.format('%.17g'", "redis.call('TIME')"} {
		if !strings.Contains(takeScriptSource, required) {
			t.Fatalf("script lacks %q", required)
		}
	}
}
