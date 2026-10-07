package ratelimit

import (
	"context"
	"sync"
	"time"
)

// MemoryBackend is a single-process reference backend with an injectable
// clock. It implements the same arithmetic as the Redis script.
type MemoryBackend struct {
	mu      sync.Mutex
	now     func() time.Time
	epoch   time.Time
	buckets map[string]memoryBucket
}

type memoryBucket struct {
	tokens  float64
	updated time.Duration
	expires time.Duration
}

// NewMemoryBackend creates an empty backend. A nil clock uses time.Now.
func NewMemoryBackend(now func() time.Time) *MemoryBackend {
	if now == nil {
		now = time.Now
	}
	return &MemoryBackend{now: now, epoch: now(), buckets: make(map[string]memoryBucket)}
}

// Take atomically checks and consumes every charge, or none of them.
func (backend *MemoryBackend) Take(ctx context.Context, charges []Charge) (TakeResult, error) {
	if err := ctx.Err(); err != nil {
		return TakeResult{}, err
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	now := backend.now().Sub(backend.epoch)
	tokens := make([]float64, len(charges))
	var result TakeResult
	for index, charge := range charges {
		available := float64(charge.Bucket.Capacity)
		if stored, ok := backend.buckets[charge.Key]; ok && now < stored.expires {
			available = refill(charge.Bucket, stored.tokens, stored.updated, now)
		}
		tokens[index] = available
		if available < float64(charge.Cost) {
			result.Short = append(result.Short, index)
			result.Wait = max(result.Wait, shortfallWait(charge.Bucket, available, charge.Cost))
		}
	}
	if len(result.Short) > 0 {
		return result, nil
	}
	for index, charge := range charges {
		backend.buckets[charge.Key] = memoryBucket{
			tokens:  tokens[index] - float64(charge.Cost),
			updated: now,
			expires: now + fullRefillTTL(charge.Bucket),
		}
	}
	result.Admitted = true
	return result, nil
}

// Stored reports a key's stored tokens, for tests that assert untouched state.
func (backend *MemoryBackend) Stored(key string) (float64, bool) {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	stored, ok := backend.buckets[key]
	if !ok || backend.now().Sub(backend.epoch) >= stored.expires {
		return 0, false
	}
	return stored.tokens, true
}
