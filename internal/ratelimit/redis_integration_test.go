//go:build integration

package ratelimit

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gomodule/redigo/redis"
)

const testRedisURL = "DANS_TEST_REDIS_URL"

func redisClient(t *testing.T) *RedisClient {
	t.Helper()
	rawURL := os.Getenv(testRedisURL)
	if rawURL == "" {
		t.Skipf("%s is not set", testRedisURL)
	}
	client, err := NewRedisClient(rawURL, 500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	if _, err := redisDo(t, client, "PING"); err != nil {
		t.Fatalf("ping test Redis: %v", err)
	}
	return client
}

// redisDo runs one inspection command outside the backend under test.
func redisDo(t *testing.T, client *RedisClient, command string, args ...any) (any, error) {
	t.Helper()
	conn, err := client.pool.GetContext(context.Background())
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	return conn.Do(command, args...)
}

func uniquePrefix(t *testing.T) string {
	t.Helper()
	return fmt.Sprintf("dans:rl:{test-%d}:", time.Now().UnixNano())
}

func TestRedisBackendConformance(t *testing.T) {
	client := redisClient(t)
	backend, err := NewRedisBackend(client)
	if err != nil {
		t.Fatal(err)
	}
	prefix := uniquePrefix(t)
	runConformance(t, prefix, func(t *testing.T) conformanceBackend {
		return conformanceBackend{backend: backend, advance: time.Sleep}
	})
	keys, err := redis.Strings(redisDo(t, client, "KEYS", prefix+"*"))
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range keys {
		_, _ = redisDo(t, client, "DEL", key)
	}
}

func TestRedisBackendDoesNotOverspendAcrossClients(t *testing.T) {
	rawURL := os.Getenv(testRedisURL)
	redisClient(t)
	const instances, workers, perWorker = 2, 8, 40
	backends := make([]*RedisBackend, instances)
	for index := range backends {
		client, err := NewRedisClient(rawURL, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = client.Close() })
		backends[index], _ = NewRedisBackend(client)
	}
	prefix := uniquePrefix(t)
	requests := charge(prefix+"req", BucketRequests, 100, 1, 1)
	changes := charge(prefix+"chg", BucketChanges, 150, 1, 2)

	var admitted atomic.Int64
	var failures atomic.Int64
	started := time.Now()
	var group sync.WaitGroup
	for worker := range instances * workers {
		backend := backends[worker%instances]
		group.Go(func() {
			for range perWorker {
				result, err := backend.Take(context.Background(), []Charge{requests, changes})
				if err != nil {
					failures.Add(1)
					continue
				}
				if result.Admitted {
					admitted.Add(1)
				}
			}
		})
	}
	group.Wait()
	elapsed := time.Since(started).Seconds()
	if failures.Load() != 0 {
		t.Fatalf("%d takes failed", failures.Load())
	}
	// The change bucket (150 tokens, 2 per request) admits at most 75 plus
	// whatever refilled during the run.
	limit := int64(75 + elapsed*1/2 + 1)
	if got := admitted.Load(); got > limit || got < 75 {
		t.Fatalf("admitted %d requests in %.2fs, want 75..%d", got, elapsed, limit)
	}
}

func TestRedisBackendThrottleLeavesOtherBucketsUntouched(t *testing.T) {
	client := redisClient(t)
	backend, _ := NewRedisBackend(client)
	prefix := uniquePrefix(t)
	requests := charge(prefix+"req", BucketRequests, 50, 0.000001, 1)
	changes := charge(prefix+"chg", BucketChanges, 4, 0.000001, 4)
	if !take(t, backend, requests, changes).Admitted {
		t.Fatal("first take refused")
	}
	before, err := redis.Float64(redisDo(t, client, "HGET", requests.Key, "t"))
	if err != nil {
		t.Fatal(err)
	}
	if take(t, backend, requests, changes).Admitted {
		t.Fatal("second take admitted without change tokens")
	}
	after, err := redis.Float64(redisDo(t, client, "HGET", requests.Key, "t"))
	if err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("request tokens changed from %v to %v on a refused take", before, after)
	}
}

func TestRedisBackendExpiresIdleState(t *testing.T) {
	client := redisClient(t)
	backend, _ := NewRedisBackend(client)
	bucket := charge(uniquePrefix(t)+"ttl", BucketRequests, 2, 10, 2)
	take(t, backend, bucket)
	ttlMillis, err := redis.Int64(redisDo(t, client, "PTTL", bucket.Key))
	if err != nil {
		t.Fatal(err)
	}
	ttl := time.Duration(ttlMillis) * time.Millisecond
	if ttl <= time.Second || ttl > 1200*time.Millisecond {
		t.Fatalf("TTL = %s, want the 200ms full-refill time plus 1s", ttl)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		exists, err := redis.Int64(redisDo(t, client, "EXISTS", bucket.Key))
		if err != nil {
			t.Fatal(err)
		}
		if exists == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("idle bucket state did not expire")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !take(t, backend, bucket).Admitted {
		t.Fatal("expired state did not behave as a full bucket")
	}
}

func TestRedisBackendClassifiesUnavailableServers(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	// A listener that never answers simulates a slow server.
	t.Cleanup(func() { _ = listener.Close() })
	slow, err := NewRedisClient("redis://"+address, 50*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	defer slow.Close()
	slowBackend, _ := NewRedisBackend(slow)
	started := time.Now()
	takeCtx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	_, err = slowBackend.Take(takeCtx, []Charge{charge("dans:rl:{x}:req", BucketRequests, 1, 1, 1)})
	cancel()
	if err == nil || Classify(err) != ReasonTimeout {
		t.Fatalf("slow server error = %v (%s), want timeout", err, Classify(err))
	}
	if waited := time.Since(started); waited > 500*time.Millisecond {
		t.Fatalf("slow server blocked for %s, beyond the client timeout", waited)
	}

	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	refusedAddress := closed.Addr().String()
	_ = closed.Close()
	refused, err := NewRedisClient("redis://"+refusedAddress, 50*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	defer refused.Close()
	refusedBackend, _ := NewRedisBackend(refused)
	_, err = refusedBackend.Take(context.Background(), []Charge{charge("dans:rl:{x}:req", BucketRequests, 1, 1, 1)})
	if err == nil || Classify(err) != ReasonConnection {
		t.Fatalf("refused error = %v (%s), want connection", err, Classify(err))
	}
	if errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("refused connection reported as a deadline")
	}
}
