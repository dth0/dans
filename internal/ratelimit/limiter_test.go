package ratelimit

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)}
}

func (clock *fakeClock) Now() time.Time {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	return clock.now
}

func (clock *fakeClock) Advance(duration time.Duration) {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	clock.now = clock.now.Add(duration)
}

type failingBackend struct {
	err   error
	calls int
}

func (backend *failingBackend) Take(context.Context, []Charge) (TakeResult, error) {
	backend.calls++
	return TakeResult{}, backend.err
}

func newTestLimiter(t *testing.T, table *Table, backend Backend, logs *bytes.Buffer) *Limiter {
	t.Helper()
	logger := slog.New(slog.NewJSONHandler(logs, nil))
	limiter, err := NewLimiter(LimiterConfig{
		Table: table, Backend: backend, Timeout: 25 * time.Millisecond,
		Reporter: NewReporter(logger, time.Second, nil),
	})
	if err != nil {
		t.Fatal(err)
	}
	return limiter
}

func TestChangeCostSumsBatchByKind(t *testing.T) {
	policy := BuiltinPolicy()
	kinds := []string{"REPLACE", "REPLACE", "REPLACE", "DELETE", "EXTEND"}
	if got := policy.ChangeCost(PatchZoneOperation, kinds); got != 8 {
		t.Fatalf("mixed batch cost = %d, want 8", got)
	}
	if got := policy.ChangeCost(PatchZoneOperation, []string{"PRUNE"}); got != 1 {
		t.Fatalf("PRUNE cost = %d, want 1", got)
	}
	if got := policy.ChangeCost("createZone", nil); got != 2 {
		t.Fatalf("createZone cost = %d, want 2", got)
	}
	if got := policy.ChangeCost("deleteZone", nil); got != 2 {
		t.Fatalf("deleteZone cost = %d, want 2", got)
	}
	if got := policy.ChangeCost("listZones", nil); got != 0 {
		t.Fatalf("read cost = %d, want 0", got)
	}
	if got := policy.ChangeCost(PatchZoneOperation, nil); got != 0 {
		t.Fatalf("uncharged batch cost = %d, want 0", got)
	}
}

func TestChargesListBucketsInPublicOrder(t *testing.T) {
	policy := BuiltinPolicy()
	read := Charges(policy, Request{IdentityID: testIdentity, Operation: "listZones"})
	if names := chargeNames(read); !slices.Equal(names, []BucketName{BucketRequests, BucketOperation}) {
		t.Fatalf("read charges = %v", names)
	}
	write := Charges(policy, Request{IdentityID: testIdentity, Operation: PatchZoneOperation, ChangeKinds: []string{"DELETE"}})
	if names := chargeNames(write); !slices.Equal(names, []BucketName{BucketRequests, BucketOperation, BucketChanges}) {
		t.Fatalf("write charges = %v", names)
	}
	for _, charge := range write {
		if want := "dans:rl:{" + testIdentity + "}:"; charge.Key[:len(want)] != want {
			t.Fatalf("key %q does not share the identity hash tag", charge.Key)
		}
	}
}

func chargeNames(charges []Charge) []BucketName {
	names := make([]BucketName, len(charges))
	for index, charge := range charges {
		names[index] = charge.Name
	}
	return names
}

func TestLimiterRejectsCostAboveCapacityWithoutBackend(t *testing.T) {
	table, _, err := ParsePolicy([]byte(`{"defaults": {"changes": {"capacity": 50}}}`), testOperations)
	if err != nil {
		t.Fatal(err)
	}
	backend := &failingBackend{err: errors.New("unreachable")}
	limiter := newTestLimiter(t, table, backend, new(bytes.Buffer))
	kinds := slices.Repeat([]string{"REPLACE"}, 30)
	decision := limiter.Admit(context.Background(), Request{IdentityID: testIdentity, Operation: PatchZoneOperation, ChangeKinds: kinds})
	if decision.Outcome != OutcomeExceedsCapacity {
		t.Fatalf("outcome = %s, want exceeds_capacity", decision.Outcome)
	}
	if want := []Exceeded{{Bucket: BucketChanges, Cost: 60, Capacity: 50}}; !slices.Equal(decision.Exceeded, want) {
		t.Fatalf("exceeded = %+v, want %+v", decision.Exceeded, want)
	}
	if backend.calls != 0 {
		t.Fatalf("backend called %d times for a request that can never fit", backend.calls)
	}
}

func TestLimiterFailsOpenOnBackendError(t *testing.T) {
	logs := new(bytes.Buffer)
	backend := &failingBackend{err: context.DeadlineExceeded}
	limiter := newTestLimiter(t, NewBuiltinTable(), backend, logs)
	decision := limiter.Admit(context.Background(), Request{IdentityID: testIdentity, Operation: PatchZoneOperation, ChangeKinds: []string{"DELETE"}})
	if decision.Outcome != OutcomeUnmetered || decision.ChangeCost != 1 {
		t.Fatalf("decision = %+v, want unmetered with cost 1", decision)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"`+EventFailOpen+`"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"timeout"`)) {
		t.Fatalf("missing fail-open warning: %s", logs)
	}
}

func TestLimiterDoesNotReportCanceledCallers(t *testing.T) {
	logs := new(bytes.Buffer)
	limiter := newTestLimiter(t, NewBuiltinTable(), &failingBackend{err: context.Canceled}, logs)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if decision := limiter.Admit(ctx, Request{IdentityID: testIdentity, Operation: "listZones"}); decision.Outcome != OutcomeUnmetered {
		t.Fatalf("outcome = %s", decision.Outcome)
	}
	if logs.Len() != 0 {
		t.Fatalf("canceled caller reported as backend failure: %s", logs)
	}
}

func TestLimiterReportsShortBucketsAndWait(t *testing.T) {
	clock := newFakeClock()
	limiter := newTestLimiter(t, NewBuiltinTable(), NewMemoryBackend(clock.Now), new(bytes.Buffer))
	request := Request{IdentityID: testIdentity, Operation: "createZone"}
	for range 40 {
		if decision := limiter.Admit(context.Background(), request); decision.Outcome != OutcomeAdmitted {
			t.Fatalf("burst request %s", decision.Outcome)
		}
	}
	decision := limiter.Admit(context.Background(), request)
	if decision.Outcome != OutcomeThrottled || !slices.Equal(decision.Short, []BucketName{BucketOperation}) {
		t.Fatalf("decision = %+v, want operation throttle", decision)
	}
	if decision.RetryAfter != 500*time.Millisecond || RetryAfterSeconds(decision.RetryAfter) != 1 {
		t.Fatalf("retry after = %s", decision.RetryAfter)
	}
	other := limiter.Admit(context.Background(), Request{IdentityID: testIdentity, Operation: "listZones"})
	if other.Outcome != OutcomeAdmitted {
		t.Fatalf("other operation = %s, want admitted while identity bucket has tokens", other.Outcome)
	}
}

func TestDeploymentPolicyThrottlesSlowRequests(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "integration", "ratelimit", "deployment.json"))
	if err != nil {
		t.Fatal(err)
	}
	table, warnings, err := ParsePolicy(data, testOperations)
	if err != nil {
		t.Fatal(err)
	}
	if len(warnings) != 0 {
		t.Fatalf("deployment policy warnings = %v", warnings)
	}
	capacity := table.For(testIdentity).Requests.Capacity
	for _, spacing := range []time.Duration{0, 100 * time.Millisecond, 5 * time.Second} {
		t.Run(spacing.String(), func(t *testing.T) {
			clock := newFakeClock()
			limiter := newTestLimiter(t, table, NewMemoryBackend(clock.Now), new(bytes.Buffer))
			request := Request{IdentityID: testIdentity, Operation: "listZones"}
			for attempt := int64(0); attempt < capacity; attempt++ {
				if decision := limiter.Admit(context.Background(), request); decision.Outcome != OutcomeAdmitted {
					t.Fatalf("request %d = %s, want admitted", attempt+1, decision.Outcome)
				}
				clock.Advance(spacing)
			}
			decision := limiter.Admit(context.Background(), request)
			if decision.Outcome != OutcomeThrottled || !slices.Equal(decision.Short, []BucketName{BucketRequests}) {
				t.Fatalf("capacity-plus-one request = %+v, want requests throttle", decision)
			}
			if decision.RetryAfter <= 0 {
				t.Fatalf("retry after = %s, want positive", decision.RetryAfter)
			}
		})
	}
}

func TestRetryAfterSecondsRoundsUpToAtLeastOne(t *testing.T) {
	for wait, want := range map[time.Duration]int64{0: 1, time.Millisecond: 1, time.Second: 1, 1001 * time.Millisecond: 2, 2500 * time.Millisecond: 3} {
		if got := RetryAfterSeconds(wait); got != want {
			t.Errorf("RetryAfterSeconds(%s) = %d, want %d", wait, got, want)
		}
	}
}
