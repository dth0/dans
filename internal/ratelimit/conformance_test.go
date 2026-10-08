package ratelimit

import (
	"context"
	"math"
	"slices"
	"testing"
	"time"
)

// conformanceBackend is a backend under test plus a way to let time pass.
// Memory backends advance a fake clock; Redis backends sleep, so cases only
// assert lower bounds where real elapsed time can add tokens.
type conformanceBackend struct {
	backend Backend
	advance func(time.Duration)
	// exact is true when no unplanned time can elapse between calls.
	exact bool
}

func charge(key string, name BucketName, capacity int64, refill float64, cost int64) Charge {
	return Charge{Name: name, Key: key, Bucket: Bucket{Capacity: capacity, RefillPerSecond: refill}, Cost: cost}
}

func take(t *testing.T, backend Backend, charges ...Charge) TakeResult {
	t.Helper()
	result, err := backend.Take(context.Background(), charges)
	if err != nil {
		t.Fatalf("take: %v", err)
	}
	return result
}

// runConformance checks the token-bucket contract every backend must meet.
// keyPrefix isolates cases that share one backend.
func runConformance(t *testing.T, keyPrefix string, newBackend func(t *testing.T) conformanceBackend) {
	const slow = 0.000001 // effectively no refill during a case

	t.Run("burst exhaustion", func(t *testing.T) {
		subject := newBackend(t)
		bucket := charge(keyPrefix+"burst", BucketRequests, 5, slow, 1)
		for index := range 5 {
			if !take(t, subject.backend, bucket).Admitted {
				t.Fatalf("request %d throttled within burst", index+1)
			}
		}
		result := take(t, subject.backend, bucket)
		if result.Admitted || !slices.Equal(result.Short, []int{0}) {
			t.Fatalf("result = %+v, want throttle on index 0", result)
		}
	})

	t.Run("weighted cost", func(t *testing.T) {
		subject := newBackend(t)
		bucket := charge(keyPrefix+"weighted", BucketChanges, 5, slow, 2)
		if !take(t, subject.backend, bucket).Admitted || !take(t, subject.backend, bucket).Admitted {
			t.Fatal("two UPSERT-weight requests should fit capacity 5")
		}
		if take(t, subject.backend, bucket).Admitted {
			t.Fatal("third cost-2 request admitted with 1 token left")
		}
		if !take(t, subject.backend, charge(keyPrefix+"weighted", BucketChanges, 5, slow, 1)).Admitted {
			t.Fatal("cost-1 request should use the remaining token")
		}
	})

	t.Run("batch cost summation", func(t *testing.T) {
		subject := newBackend(t)
		policy := BuiltinPolicy()
		policy.Changes = Bucket{Capacity: 8, RefillPerSecond: slow}
		request := Request{IdentityID: keyPrefix + "batch", Operation: PatchZoneOperation, ChangeKinds: []string{"REPLACE", "REPLACE", "REPLACE", "DELETE", "EXTEND"}}
		if !take(t, subject.backend, Charges(policy, request)...).Admitted {
			t.Fatal("cost-8 batch should fit capacity 8")
		}
		request.ChangeKinds = []string{"PRUNE"}
		result := take(t, subject.backend, Charges(policy, request)...)
		if result.Admitted || !slices.Equal(result.Short, []int{2}) {
			t.Fatalf("result = %+v, want change bucket (index 2) short", result)
		}
	})

	t.Run("all or nothing", func(t *testing.T) {
		subject := newBackend(t)
		requests := charge(keyPrefix+"aon:req", BucketRequests, 10, slow, 1)
		changes := charge(keyPrefix+"aon:chg", BucketChanges, 3, slow, 3)
		if !take(t, subject.backend, requests, changes).Admitted {
			t.Fatal("first request should fit")
		}
		result := take(t, subject.backend, requests, changes)
		if result.Admitted || !slices.Equal(result.Short, []int{1}) {
			t.Fatalf("result = %+v, want only changes short", result)
		}
		// Nine request tokens remain only if the refused request consumed none.
		for index := range 9 {
			if !take(t, subject.backend, requests).Admitted {
				t.Fatalf("request token %d was consumed by the refused request", index+1)
			}
		}
		if take(t, subject.backend, requests).Admitted {
			t.Fatal("request bucket should now be empty")
		}
	})

	t.Run("several short buckets", func(t *testing.T) {
		subject := newBackend(t)
		requests := charge(keyPrefix+"multi:req", BucketRequests, 1, 1, 1)
		operation := charge(keyPrefix+"multi:op", BucketOperation, 1, 0.5, 1)
		take(t, subject.backend, requests, operation)
		result := take(t, subject.backend, requests, operation)
		if result.Admitted || !slices.Equal(result.Short, []int{0, 1}) {
			t.Fatalf("result = %+v, want both short", result)
		}
		if result.Wait < 1500*time.Millisecond || result.Wait > 2*time.Second {
			t.Fatalf("wait = %s, want the slower bucket's wait (about 2s)", result.Wait)
		}
	})

	t.Run("cost above capacity is rejected", func(t *testing.T) {
		subject := newBackend(t)
		bucket := charge(keyPrefix+"over", BucketChanges, 5, 1, 6)
		result, err := subject.backend.Take(context.Background(), []Charge{bucket})
		if err == nil && result.Admitted {
			t.Fatal("cost above capacity was admitted")
		}
	})

	t.Run("partial refill", func(t *testing.T) {
		subject := newBackend(t)
		bucket := charge(keyPrefix+"refill", BucketRequests, 50, 10, 1)
		for range 50 {
			take(t, subject.backend, bucket)
		}
		subject.advance(time.Second)
		admitted := 0
		for take(t, subject.backend, bucket).Admitted {
			admitted++
			if admitted > 50 {
				t.Fatal("bucket refilled above capacity")
			}
		}
		if admitted < 10 || subject.exact && admitted != 10 {
			t.Fatalf("admitted %d after 1s at 10/s", admitted)
		}
	})

	t.Run("retry after", func(t *testing.T) {
		subject := newBackend(t)
		bucket := charge(keyPrefix+"retry", BucketChanges, 10, 4, 10)
		take(t, subject.backend, bucket)
		result := take(t, subject.backend, bucket)
		if result.Admitted {
			t.Fatal("empty bucket admitted a cost-10 request")
		}
		if result.Wait > 2500*time.Millisecond || subject.exact && result.Wait != 2500*time.Millisecond {
			t.Fatalf("wait = %s, want 2.5s for 10 tokens at 4/s", result.Wait)
		}
		if result.Wait < 2*time.Second {
			t.Fatalf("wait = %s, too short", result.Wait)
		}
	})
}

func TestMemoryBackendConformance(t *testing.T) {
	runConformance(t, "", func(t *testing.T) conformanceBackend {
		clock := newFakeClock()
		return conformanceBackend{backend: NewMemoryBackend(clock.Now), advance: clock.Advance, exact: true}
	})
}

func TestMemoryBackendClampsStoredTokensToReducedCapacity(t *testing.T) {
	clock := newFakeClock()
	backend := NewMemoryBackend(clock.Now)
	take(t, backend, charge("clamp", BucketChanges, 1500, 100, 1))
	reduced := charge("clamp", BucketChanges, 10, 0.000001, 1)
	admitted := 0
	for take(t, backend, reduced).Admitted {
		admitted++
		if admitted > 20 {
			t.Fatal("stored tokens above the new capacity were usable")
		}
	}
	if admitted != 10 {
		t.Fatalf("admitted %d, want the reduced capacity 10", admitted)
	}
}

func TestMemoryBackendExpiredStateEqualsFullBucket(t *testing.T) {
	clock := newFakeClock()
	backend := NewMemoryBackend(clock.Now)
	bucket := charge("expiry", BucketRequests, 20, 10, 20)
	take(t, backend, bucket)
	if tokens, ok := backend.Stored("expiry"); !ok || tokens != 0 {
		t.Fatalf("stored = %v, %v", tokens, ok)
	}
	if ttl := fullRefillTTL(bucket.Bucket); ttl != 3*time.Second {
		t.Fatalf("ttl = %s, want full refill 2s plus 1s", ttl)
	}
	clock.Advance(2 * time.Second)
	if tokens, ok := backend.Stored("expiry"); !ok || math.Abs(tokens) > 0 {
		t.Fatalf("state expired before the full-refill time: %v, %v", tokens, ok)
	}
	clock.Advance(time.Second)
	if _, ok := backend.Stored("expiry"); ok {
		t.Fatal("state outlived its TTL")
	}
	if !take(t, backend, bucket).Admitted {
		t.Fatal("expired state did not behave as a full bucket")
	}
}

func TestMemoryBackendIgnoresBackwardClockSteps(t *testing.T) {
	clock := newFakeClock()
	backend := NewMemoryBackend(clock.Now)
	bucket := charge("backwards", BucketRequests, 2, 1, 2)
	take(t, backend, bucket)
	clock.Advance(-time.Hour)
	if take(t, backend, bucket).Admitted {
		t.Fatal("a backward clock step added tokens")
	}
}

func TestMemoryBackendPreservesWatermarkDuringAdmittedBackwardStep(t *testing.T) {
	for _, expiryOnly := range []bool{false, true} {
		name := "no double refill"
		if expiryOnly {
			name = "expiry follows watermark"
		}
		t.Run(name, func(t *testing.T) {
			clock := newFakeClock()
			backend := NewMemoryBackend(clock.Now)
			clock.Advance(100 * time.Second)
			bucket := charge("backwards-admitted", BucketRequests, 10, 1, 5)
			if !take(t, backend, bucket).Admitted {
				t.Fatal("initial request was refused")
			}
			bucket.Cost = 1
			clock.Advance(-10 * time.Second)
			if !take(t, backend, bucket).Admitted {
				t.Fatal("request during backward step was refused")
			}
			if tokens, ok := backend.Stored(bucket.Key); !ok || tokens != 4 {
				t.Fatalf("backward-step state = %v, %v, want 4 tokens", tokens, ok)
			}
			if expiryOnly {
				clock.Advance(11 * time.Second)
				if _, ok := backend.Stored(bucket.Key); !ok {
					t.Fatal("state expired before the watermark's full-refill time")
				}
				clock.Advance(10 * time.Second)
				if _, ok := backend.Stored(bucket.Key); ok {
					t.Fatal("state outlived the watermark's full-refill time plus 1s")
				}
				return
			}
			clock.Advance(10 * time.Second)
			if !take(t, backend, bucket).Admitted {
				t.Fatal("request after clock recovery was refused")
			}
			if tokens, ok := backend.Stored(bucket.Key); !ok || tokens != 3 {
				t.Fatalf("recovered state = %v, %v, want 3 tokens without double refill", tokens, ok)
			}
			clock.Advance(time.Second)
			if !take(t, backend, bucket).Admitted {
				t.Fatal("request after new forward progress was refused")
			}
			if tokens, ok := backend.Stored(bucket.Key); !ok || tokens != 3 {
				t.Fatalf("forward state = %v, %v, want normal refill to resume", tokens, ok)
			}
		})
	}
}

func TestMemoryBackendLongExpiryDoesNotOverflow(t *testing.T) {
	clock := newFakeClock()
	backend := NewMemoryBackend(clock.Now)
	clock.Advance(time.Hour)
	maxMillis := int64((time.Duration(math.MaxInt64) - time.Second) / time.Millisecond)
	rate := math.Nextafter(1000/float64(maxMillis), math.Inf(1))
	bucket := charge("long-expiry", BucketRequests, 1, rate, 1)
	if !take(t, backend, bucket).Admitted {
		t.Fatal("full bucket was not admitted")
	}
	clock.Advance(time.Hour)
	if _, ok := backend.Stored(bucket.Key); !ok {
		t.Fatal("long-lived state expired due to arithmetic overflow")
	}
	result := take(t, backend, bucket)
	if result.Admitted || result.Wait <= 0 {
		t.Fatalf("result = %+v, want a positive retry wait", result)
	}
}
