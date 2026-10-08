package ratelimit

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"math"
	"net"
	"net/url"
	"strconv"
	"time"

	"github.com/gomodule/redigo/redis"
)

//go:embed take.lua
var takeScriptSource string

// takeScript passes its key count as the first argument; DoContext sends
// EVALSHA and falls back to EVAL when the server has not cached the script.
var takeScript = redis.NewScript(-1, takeScriptSource)

const (
	redisMaxIdle     = 16
	redisMaxActive   = 64
	redisIdleTimeout = time.Minute
)

// RedisClient is a fail-fast connection pool. Every network wait is bounded
// by the configured timeout, commands are never retried, no connection is
// opened until the first request, and broken connections are discarded so
// the pool redials on demand once Redis is reachable again.
type RedisClient struct {
	pool    *redis.Pool
	timeout time.Duration
}

// NewRedisClient builds a pool from a redis:// or rediss:// URL whose user
// information and path carry the ACL user, password, and database.
func NewRedisClient(rawURL string, timeout time.Duration) (*RedisClient, error) {
	if err := ParseRedisURL(rawURL); err != nil {
		return nil, err
	}
	if timeout <= 0 {
		return nil, errors.New("rate limiter: Redis timeout must be positive")
	}
	dialer := &net.Dialer{Timeout: timeout, KeepAlive: 5 * time.Minute}
	pool := &redis.Pool{
		MaxIdle:     redisMaxIdle,
		MaxActive:   redisMaxActive,
		IdleTimeout: redisIdleTimeout,
		// Waiting for a free connection is bounded by the request deadline.
		Wait: true,
		DialContext: func(ctx context.Context) (redis.Conn, error) {
			var stopCancel func() bool
			conn, err := redis.DialURLContext(ctx, rawURL,
				redis.DialContextFunc(func(ctx context.Context, network, address string) (net.Conn, error) {
					conn, err := dialer.DialContext(ctx, network, address)
					if err != nil {
						return nil, err
					}
					// Redigo's TLS handshake does not observe context cancellation.
					stopCancel = context.AfterFunc(ctx, func() { _ = conn.Close() })
					return conn, nil
				}),
				redis.DialTLSHandshakeTimeout(timeout),
				redis.DialReadTimeout(timeout),
				redis.DialWriteTimeout(timeout),
			)
			// A pooled connection must outlive the context that opened it.
			if stopCancel != nil {
				stopCancel()
			}
			if err := ctx.Err(); err != nil {
				if conn != nil {
					_ = conn.Close()
				}
				return nil, err
			}
			return conn, err
		},
	}
	return &RedisClient{pool: pool, timeout: timeout}, nil
}

// Timeout reports the per-operation network timeout.
func (client *RedisClient) Timeout() time.Duration { return client.timeout }

// Close releases every pooled connection.
func (client *RedisClient) Close() error { return client.pool.Close() }

// ParseRedisURL validates a Redis connection URL without contacting the
// server. Its error never repeats the URL, which may contain a password.
func ParseRedisURL(rawURL string) error {
	parsed, err := url.Parse(rawURL)
	if err != nil || (parsed.Scheme != "redis" && parsed.Scheme != "rediss") || parsed.Host == "" {
		return errors.New("must be a redis:// or rediss:// URL")
	}
	if port := parsed.Port(); port != "" {
		number, err := strconv.ParseUint(port, 10, 16)
		if err != nil || number == 0 {
			return errors.New("Redis URL port must be between 1 and 65535")
		}
	}
	if parsed.Path != "" && parsed.Path != "/" {
		// Redigo accepts decimal database numbers that fit in an int.
		if _, err := strconv.ParseUint(parsed.Path[1:], 10, strconv.IntSize-1); err != nil {
			return errors.New("invalid Redis URL database")
		}
	}
	return nil
}

// RedisBackend runs the check-and-consume script on a Redis-protocol server.
type RedisBackend struct {
	client *RedisClient
}

// NewRedisBackend wraps a client.
func NewRedisBackend(client *RedisClient) (*RedisBackend, error) {
	if client == nil {
		return nil, errors.New("rate limiter: missing Redis client")
	}
	return &RedisBackend{client: client}, nil
}

// Take runs the script once. Any error, including a deadline, is returned so
// the limiter can fail open.
func (backend *RedisBackend) Take(ctx context.Context, charges []Charge) (TakeResult, error) {
	if len(charges) == 0 {
		return TakeResult{Admitted: true}, nil
	}
	conn, err := backend.client.pool.GetContext(ctx)
	if err != nil {
		return TakeResult{}, err
	}
	defer conn.Close()
	args := make([]any, 0, 1+len(charges)*4)
	args = append(args, len(charges))
	for _, charge := range charges {
		args = append(args, charge.Key)
	}
	for _, charge := range charges {
		args = append(args,
			strconv.FormatInt(charge.Bucket.Capacity, 10),
			strconv.FormatFloat(charge.Bucket.RefillPerSecond, 'g', -1, 64),
			strconv.FormatInt(charge.Cost, 10),
		)
	}
	reply, err := redis.Int64s(takeScript.DoContext(ctx, conn, args...))
	if err != nil {
		return TakeResult{}, err
	}
	return parseTakeReply(reply, len(charges))
}

func parseTakeReply(reply []int64, charges int) (TakeResult, error) {
	if len(reply) == 0 {
		return TakeResult{}, errors.New("rate limiter: empty script reply")
	}
	switch reply[0] {
	case 0:
		return TakeResult{Admitted: true}, nil
	case 1:
		if len(reply) < 3 {
			return TakeResult{}, errors.New("rate limiter: malformed throttle reply")
		}
		if reply[1] < 0 || reply[1] > math.MaxInt64/int64(time.Millisecond) {
			return TakeResult{}, errors.New("rate limiter: script reply wait out of range")
		}
		result := TakeResult{Wait: time.Duration(reply[1]) * time.Millisecond}
		for _, index := range reply[2:] {
			if index < 0 || index >= int64(charges) {
				return TakeResult{}, errors.New("rate limiter: script reply index out of range")
			}
			result.Short = append(result.Short, int(index))
		}
		return result, nil
	case 2:
		return TakeResult{}, fmt.Errorf("rate limiter: script rejected a cost above capacity")
	default:
		return TakeResult{}, errors.New("rate limiter: unknown script reply")
	}
}
