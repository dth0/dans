package ratelimit

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"
)

// BucketName is the public name of a bucket in headers, errors, and logs.
type BucketName string

const (
	BucketRequests  BucketName = "requests"
	BucketOperation BucketName = "operation"
	BucketChanges   BucketName = "changes"
)

// Outcome is the rate-limit result recorded for a metered request.
type Outcome string

const (
	OutcomeAdmitted        Outcome = "admitted"
	OutcomeThrottled       Outcome = "throttled"
	OutcomeExceedsCapacity Outcome = "exceeds_capacity"
	OutcomeUnmetered       Outcome = "unmetered"
)

// Request describes one authenticated request to meter.
type Request struct {
	IdentityID string
	Operation  string
	// ChangeKinds lists each RRset change kind of an accepted zone PATCH batch.
	ChangeKinds []string
}

// Exceeded reports a bucket whose capacity is smaller than the request cost.
type Exceeded struct {
	Bucket   BucketName
	Cost     int64
	Capacity int64
}

// Decision is the rate-limit result for one request.
type Decision struct {
	Outcome     Outcome
	Short       []BucketName
	Exceeded    []Exceeded
	RetryAfter  time.Duration
	RequestCost int64
	ChangeCost  int64
	Latency     time.Duration
}

// Charge is one bucket a request must pay.
type Charge struct {
	Name   BucketName
	Key    string
	Bucket Bucket
	Cost   int64
}

// TakeResult is a backend's atomic check-and-consume outcome.
type TakeResult struct {
	Admitted bool
	// Short holds indexes into the charges that lacked tokens.
	Short []int
	Wait  time.Duration
}

// Backend atomically checks and consumes every charge, or none of them.
type Backend interface {
	Take(context.Context, []Charge) (TakeResult, error)
}

// Limiter applies policies, computes costs, and fails open around a backend.
type Limiter struct {
	table    *Table
	backend  Backend
	timeout  time.Duration
	reporter *Reporter
	now      func() time.Time
}

// LimiterConfig assembles a Limiter.
type LimiterConfig struct {
	Table    *Table
	Backend  Backend
	Timeout  time.Duration
	Reporter *Reporter
	Now      func() time.Time
}

// NewLimiter validates its dependencies.
func NewLimiter(config LimiterConfig) (*Limiter, error) {
	if config.Table == nil || config.Backend == nil || config.Reporter == nil || config.Timeout <= 0 {
		return nil, errors.New("rate limiter: missing dependency")
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Limiter{table: config.Table, backend: config.Backend, timeout: config.Timeout, reporter: config.Reporter, now: now}, nil
}

// Admit meters one request. It never returns an error: backend failures
// produce an unmetered decision so throttling fails open.
func (limiter *Limiter) Admit(ctx context.Context, request Request) Decision {
	started := limiter.now()
	policy := limiter.table.For(request.IdentityID)
	charges := Charges(policy, request)
	decision := Decision{RequestCost: 1, ChangeCost: policy.ChangeCost(request.Operation, request.ChangeKinds)}
	finish := func(decision Decision) Decision {
		decision.Latency = limiter.now().Sub(started)
		return decision
	}

	for _, charge := range charges {
		if charge.Cost > charge.Bucket.Capacity {
			decision.Exceeded = append(decision.Exceeded, Exceeded{Bucket: charge.Name, Cost: charge.Cost, Capacity: charge.Bucket.Capacity})
		}
	}
	if len(decision.Exceeded) > 0 {
		decision.Outcome = OutcomeExceedsCapacity
		return finish(decision)
	}

	takeCtx, cancel := context.WithTimeout(ctx, limiter.timeout)
	result, err := limiter.backend.Take(takeCtx, charges)
	cancel()
	if err != nil {
		decision.Outcome = OutcomeUnmetered
		if ctx.Err() == nil {
			limiter.reporter.Failure(err)
		}
		return finish(decision)
	}
	limiter.reporter.Success()
	if result.Admitted {
		decision.Outcome = OutcomeAdmitted
		return finish(decision)
	}
	decision.Outcome = OutcomeThrottled
	for _, index := range result.Short {
		if index >= 0 && index < len(charges) {
			decision.Short = append(decision.Short, charges[index].Name)
		}
	}
	decision.RetryAfter = result.Wait
	return finish(decision)
}

// Charges lists the buckets one request pays, in public bucket order.
func Charges(policy Policy, request Request) []Charge {
	charges := []Charge{
		{Name: BucketRequests, Key: bucketKey(request.IdentityID, "req"), Bucket: policy.Requests, Cost: 1},
		{Name: BucketOperation, Key: bucketKey(request.IdentityID, "op:"+request.Operation), Bucket: policy.OperationBucket(request.Operation), Cost: 1},
	}
	if cost := policy.ChangeCost(request.Operation, request.ChangeKinds); cost > 0 {
		charges = append(charges, Charge{Name: BucketChanges, Key: bucketKey(request.IdentityID, "chg"), Bucket: policy.Changes, Cost: cost})
	}
	return charges
}

// bucketKey shares one Redis Cluster hash tag across an identity's buckets so
// the multi-key script stays in one slot.
func bucketKey(identityID, suffix string) string {
	return fmt.Sprintf("dans:rl:{%s}:%s", identityID, suffix)
}

// RetryAfterSeconds converts a wait into a whole-second Retry-After of at least 1.
func RetryAfterSeconds(wait time.Duration) int64 {
	return max(1, int64(math.Ceil(wait.Seconds())))
}

// refill returns the tokens available at now for a bucket last updated at
// updated with stored tokens. Elapsed time never runs backwards.
func refill(bucket Bucket, stored float64, updated, now time.Duration) float64 {
	elapsed := max(0, now-updated)
	return min(float64(bucket.Capacity), stored+elapsed.Seconds()*bucket.RefillPerSecond)
}

// fullRefillTTL is how long state must live before a missing key is
// indistinguishable from the stored bucket: the full refill time plus 1s.
func fullRefillTTL(bucket Bucket) time.Duration {
	seconds := float64(bucket.Capacity) / bucket.RefillPerSecond
	return time.Duration(math.Ceil(seconds*1000))*time.Millisecond + time.Second
}

// shortfallWait is the time until a bucket holding tokens could pay cost.
func shortfallWait(bucket Bucket, tokens float64, cost int64) time.Duration {
	missing := float64(cost) - tokens
	if missing <= 0 {
		return 0
	}
	return time.Duration(math.Ceil(missing/bucket.RefillPerSecond*1000)) * time.Millisecond
}
