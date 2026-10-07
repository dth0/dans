package httpserver

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ncode/dans/api"
	"github.com/ncode/dans/internal/database"
	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/ratelimit"
	"github.com/ncode/dans/internal/upstream"
)

const (
	limitedIdentity = "00000000-0000-4000-8000-0000000000a1"
	otherIdentity   = "00000000-0000-4000-8000-0000000000b2"
)

type fakeRateLimiter struct {
	mu       sync.Mutex
	decision ratelimit.Decision
	requests []ratelimit.Request
}

func (limiter *fakeRateLimiter) Admit(_ context.Context, request ratelimit.Request) ratelimit.Decision {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	limiter.requests = append(limiter.requests, request)
	return limiter.decision
}

func (limiter *fakeRateLimiter) calls() []ratelimit.Request {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	return slices.Clone(limiter.requests)
}

type failingRateBackend struct{}

func (failingRateBackend) Take(context.Context, []ratelimit.Charge) (ratelimit.TakeResult, error) {
	return ratelimit.TakeResult{}, errors.New("dial redis://:secret@redis.internal:6379 refused")
}

type rateLimitApp struct {
	handler       http.Handler
	upstreamCalls *atomic.Int64
	upstreamBody  *atomic.Value
	mutations     *recordingMutationStore
	denials       *recordingDenialAuditor
	logs          *bytes.Buffer
}

// otherToken is a second well-formed API token that maps to otherIdentity.
func otherToken() string {
	return "dans_v1_" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
}

// newRateLimitApp assembles the production chain. validToken() maps to
// limitedIdentity and every other token to otherIdentity.
func newRateLimitApp(t *testing.T, limiter RateLimiter, operator bool) rateLimitApp {
	t.Helper()
	var calls atomic.Int64
	var body atomic.Value
	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		payload, _ := io.ReadAll(request.Body)
		body.Store(string(payload))
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-PowerDNS-Extension", "preserved")
		if request.Method == http.MethodPatch {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		_, _ = io.WriteString(w, `[]`)
	}))
	t.Cleanup(upstreamServer.Close)
	client, err := upstream.New(upstream.TransportConfig{URL: upstreamServer.URL, Timeout: time.Second}, httpapi.NewSecret("powerdns-key"))
	if err != nil {
		t.Fatal(err)
	}
	health, err := NewHealth(passingDependencies(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	actorFor := func(token string) database.Actor {
		identity := limitedIdentity
		if token != validToken() {
			identity = otherIdentity
		}
		return database.Actor{IdentityID: identity, TokenID: "00000000-0000-4000-8000-000000000020", Operator: operator}
	}
	mutations := &recordingMutationStore{decision: database.AuthorizationDecision{Allowed: true, Actor: actorFor(validToken())}}
	denials := &recordingDenialAuditor{}
	logs := new(bytes.Buffer)
	handler, err := NewApplicationHandler(ApplicationConfig{
		Boundary: BoundaryConfig{MaxBodyBytes: 1 << 20, RequestTimeout: time.Second, MaxConcurrent: 8},
		Logger:   NewJSONLogger(logs, slog.LevelInfo),
		Authenticator: authenticatorFunc(func(_ context.Context, token string) (database.Actor, error) {
			return actorFor(token), nil
		}),
		Schema:            func(context.Context) error { return nil },
		PowerDNSReady:     func() bool { return true },
		Health:            health,
		Upstream:          client,
		DANS:              &testDANSHandler{},
		Mutations:         mutations,
		Lifecycle:         &recordingZoneLifecycle{},
		Denials:           denials,
		AuditFailures:     &recordingAuditFailureReporter{},
		LifecycleFailures: &recordingAuditFailureReporter{},
		UpstreamID:        "primary",
		MutationTimeout:   time.Second,
		RateLimiter:       limiter,
	})
	if err != nil {
		t.Fatal(err)
	}
	return rateLimitApp{handler: handler, upstreamCalls: &calls, upstreamBody: &body, mutations: mutations, denials: denials, logs: logs}
}

func (app rateLimitApp) do(method, path string, body []byte) *httptest.ResponseRecorder {
	return app.doAs(validToken(), method, path, body)
}

func (app rateLimitApp) doAs(token, method, path string, body []byte) *httptest.ResponseRecorder {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request := httptest.NewRequest(method, path, reader)
	if token != "" {
		request.Header.Set("X-API-Key", token)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	app.handler.ServeHTTP(response, request)
	return response
}

func zonePatch(t *testing.T, kinds ...string) []byte {
	t.Helper()
	patch := api.ZonePatch{Rrsets: make([]api.RRSetChange, len(kinds))}
	for index, kind := range kinds {
		change := api.RRSetChange{Name: "www.example.org.", Type: "A", Changetype: api.RRSetChangeChangetype(kind)}
		if kind != "DELETE" {
			records := []api.Record{{Content: "192.0.2.1", Disabled: new(false)}}
			change.Ttl, change.Records = new(300), &records
		}
		patch.Rrsets[index] = change
	}
	payload, err := json.Marshal(patch)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func decodeErrorBody(t *testing.T, response *httptest.ResponseRecorder) httpapi.ErrorResponse {
	t.Helper()
	var body httpapi.ErrorResponse
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error body %q: %v", response.Body.String(), err)
	}
	return body
}

func lastAccessLog(t *testing.T, logs *bytes.Buffer) map[string]any {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	for index := len(lines) - 1; index >= 0; index-- {
		var entry map[string]any
		if err := json.Unmarshal([]byte(lines[index]), &entry); err == nil && entry["msg"] == "http request" {
			return entry
		}
	}
	t.Fatalf("no access log in %s", logs)
	return nil
}

func TestRateLimitThrottleResponseFormat(t *testing.T) {
	limiter := &fakeRateLimiter{decision: ratelimit.Decision{
		Outcome: ratelimit.OutcomeThrottled, Short: []ratelimit.BucketName{ratelimit.BucketRequests, ratelimit.BucketOperation},
		RetryAfter: 2100 * time.Millisecond, RequestCost: 1,
	}}
	app := newRateLimitApp(t, limiter, false)
	response := app.do(http.MethodGet, "/api/v1/servers/localhost/zones", nil)
	if response.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, body %s", response.Code, response.Body)
	}
	if got := response.Header().Get("X-DANS-RateLimit-Bucket"); got != "requests, operation" {
		t.Errorf("bucket header = %q", got)
	}
	if got := response.Header().Get("Retry-After"); got != "3" {
		t.Errorf("Retry-After = %q, want 3", got)
	}
	if response.Header().Get("Cache-Control") != "no-store" || response.Header().Get("Content-Type") != "application/json" {
		t.Errorf("headers = %v", response.Header())
	}
	body := decodeErrorBody(t, response)
	if body.Error != "Rate exceeded" || !slices.Equal(body.Errors, []string{"bucket: requests", "bucket: operation"}) {
		t.Errorf("body = %+v", body)
	}
	if app.upstreamCalls.Load() != 0 {
		t.Fatal("throttled request reached PowerDNS")
	}
	if calls := limiter.calls(); len(calls) != 1 || calls[0].IdentityID != limitedIdentity || calls[0].Operation != "listZones" {
		t.Fatalf("limiter requests = %+v", calls)
	}
	if got := lastAccessLog(t, app.logs)["actor_id"]; got != limitedIdentity {
		t.Errorf("throttled actor ID = %v, want %s", got, limitedIdentity)
	}
}

func TestRateLimitCapacityResponseFormat(t *testing.T) {
	limiter := &fakeRateLimiter{decision: ratelimit.Decision{
		Outcome:  ratelimit.OutcomeExceedsCapacity,
		Exceeded: []ratelimit.Exceeded{{Bucket: ratelimit.BucketChanges, Cost: 60, Capacity: 50}},
	}}
	app := newRateLimitApp(t, limiter, false)
	response := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, "REPLACE"))
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, body %s", response.Code, response.Body)
	}
	if got := response.Header().Get("X-DANS-RateLimit-Bucket"); got != "changes" {
		t.Errorf("bucket header = %q", got)
	}
	if _, ok := response.Header()["Retry-After"]; ok {
		t.Error("413 must not include Retry-After")
	}
	body := decodeErrorBody(t, response)
	if body.Error != "request cost exceeds rate-limit capacity" || !slices.Equal(body.Errors, []string{"bucket: changes", "cost: 60", "capacity: 50"}) {
		t.Errorf("body = %+v", body)
	}
	if intents, _ := app.mutations.snapshot(); len(intents) != 0 || app.upstreamCalls.Load() != 0 {
		t.Fatal("over-capacity request wrote an intent or reached PowerDNS")
	}
	if got := lastAccessLog(t, app.logs)["actor_id"]; got != limitedIdentity {
		t.Errorf("over-capacity actor ID = %v, want %s", got, limitedIdentity)
	}
}

func TestRateLimitSkipsUnmeteredRequests(t *testing.T) {
	limiter := &fakeRateLimiter{decision: ratelimit.Decision{Outcome: ratelimit.OutcomeThrottled}}
	app := newRateLimitApp(t, limiter, false)
	for _, path := range []string{"/livez", "/readyz"} {
		if response := app.doAs("", http.MethodGet, path, nil); response.Code != http.StatusOK {
			t.Errorf("%s = %d", path, response.Code)
		}
	}
	if response := app.doAs("not-a-token", http.MethodGet, "/api/v1/servers/localhost/zones", nil); response.Code != http.StatusUnauthorized {
		t.Errorf("invalid credential = %d", response.Code)
	}
	if response := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", []byte(`{"rrsets":[{"unknown":1}]}`)); response.Code != http.StatusUnprocessableEntity {
		t.Errorf("contract-invalid = %d", response.Code)
	}
	if calls := limiter.calls(); len(calls) != 0 {
		t.Fatalf("unmetered requests were metered: %+v", calls)
	}
}

func TestRateLimitAdmittedResponseKeepsUpstreamFidelity(t *testing.T) {
	limiter := &fakeRateLimiter{decision: ratelimit.Decision{Outcome: ratelimit.OutcomeAdmitted, RequestCost: 1}}
	app := newRateLimitApp(t, limiter, false)
	response := app.do(http.MethodGet, "/api/v1/servers/localhost/zones", nil)
	if response.Code != http.StatusOK || response.Body.String() != "[]" || response.Header().Get("X-PowerDNS-Extension") != "preserved" {
		t.Fatalf("response = %d %q %v", response.Code, response.Body, response.Header())
	}
	for _, header := range []string{"Retry-After", "X-DANS-RateLimit-Bucket"} {
		if _, ok := response.Header()[header]; ok {
			t.Errorf("admitted response has %s", header)
		}
	}
}

func TestRateLimitChargesPatchByChangeKindAndRestoresBody(t *testing.T) {
	limiter := &fakeRateLimiter{decision: ratelimit.Decision{Outcome: ratelimit.OutcomeAdmitted}}
	app := newRateLimitApp(t, limiter, false)
	payload := zonePatch(t, "REPLACE", "REPLACE", "REPLACE", "DELETE", "EXTEND")
	response := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", payload)
	if response.Code != http.StatusNoContent {
		t.Fatalf("status = %d, body %s", response.Code, response.Body)
	}
	calls := limiter.calls()
	if len(calls) != 1 || calls[0].Operation != "patchZone" || !slices.Equal(calls[0].ChangeKinds, []string{"REPLACE", "REPLACE", "REPLACE", "DELETE", "EXTEND"}) {
		t.Fatalf("metered = %+v", calls)
	}
	if got, _ := app.upstreamBody.Load().(string); got != string(payload) {
		t.Fatalf("handler did not forward the restored body: %q", got)
	}
}

func TestRateLimitNeverTurnsUnsupportedBatchSizesInto413(t *testing.T) {
	limiter := newMemoryLimiter(t, `{"defaults": {"changes": {"capacity": 10}}}`, io.Discard)
	app := newRateLimitApp(t, limiter, false)
	for _, size := range []int{0, database.MaxRRsetBatch + 1} {
		response := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, slices.Repeat([]string{"REPLACE"}, size)...))
		if response.Code != http.StatusUnprocessableEntity {
			t.Fatalf("%d-RRset batch = %d, want the existing 422", size, response.Code)
		}
	}
	for _, size := range []int{0, database.MaxRRsetBatch + 1} {
		request := httptest.NewRequest(http.MethodPatch, "/", bytes.NewReader(zonePatch(t, slices.Repeat([]string{"REPLACE"}, size)...)))
		kinds, err := patchChangeKinds(request)
		if err != nil || kinds != nil {
			t.Fatalf("%d-RRset batch charged kinds %v (%v)", size, kinds, err)
		}
		if restored, _ := io.ReadAll(request.Body); len(restored) == 0 {
			t.Fatalf("%d-RRset batch body was not restored", size)
		}
	}
	if ratelimit.MaxBatchRRsets != database.MaxRRsetBatch {
		t.Fatalf("rate-limit batch bound %d differs from handler bound %d", ratelimit.MaxBatchRRsets, database.MaxRRsetBatch)
	}
}

func newMemoryLimiter(t *testing.T, policy string, logs io.Writer) *ratelimit.Limiter {
	t.Helper()
	operations, err := ContractOperationIDs()
	if err != nil {
		t.Fatal(err)
	}
	table, _, err := ratelimit.ParsePolicy([]byte(policy), operations)
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	now := func() time.Time { return clock }
	limiter, err := ratelimit.NewLimiter(ratelimit.LimiterConfig{
		Table: table, Backend: ratelimit.NewMemoryBackend(now), Timeout: 25 * time.Millisecond,
		Reporter: ratelimit.NewReporter(slog.New(slog.NewJSONHandler(logs, nil)), time.Second, now), Now: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	return limiter
}

func TestRateLimitThrottledPatchHasNoDownstreamEffects(t *testing.T) {
	limiter := newMemoryLimiter(t, `{"defaults": {"changes": {"capacity": 4, "refill_per_second": 0.001}}}`, io.Discard)
	app := newRateLimitApp(t, limiter, false)
	if response := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, "REPLACE", "REPLACE")); response.Code != http.StatusNoContent {
		t.Fatalf("first patch = %d %s", response.Code, response.Body)
	}
	intentsBefore, _ := app.mutations.snapshot()
	callsBefore := app.upstreamCalls.Load()

	response := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, "DELETE"))
	if response.Code != http.StatusTooManyRequests || response.Header().Get("X-DANS-RateLimit-Bucket") != "changes" {
		t.Fatalf("second patch = %d %v %s", response.Code, response.Header(), response.Body)
	}
	if intents, _ := app.mutations.snapshot(); len(intents) != len(intentsBefore) {
		t.Fatal("throttled patch wrote an audit intent")
	}
	if app.upstreamCalls.Load() != callsBefore {
		t.Fatal("throttled patch reached PowerDNS")
	}
	if response := app.do(http.MethodGet, "/api/v1/servers/localhost/zones", nil); response.Code != http.StatusOK {
		t.Fatalf("read after change throttle = %d, want request buckets untouched", response.Code)
	}
}

func TestRateLimitThrottlesOperatorOnlyRoutesBeforeDenialAudit(t *testing.T) {
	limiter := newMemoryLimiter(t, `{"defaults": {"requests": {"capacity": 1, "refill_per_second": 0.001}}}`, io.Discard)
	app := newRateLimitApp(t, limiter, false)
	if response := app.do(http.MethodGet, "/api/v1/servers/localhost/config", nil); response.Code != http.StatusForbidden {
		t.Fatalf("first operator-only request = %d, want 403", response.Code)
	}
	app.denials.mu.Lock()
	app.denials.input = database.AuthorizationDenialInput{}
	app.denials.mu.Unlock()

	if response := app.do(http.MethodGet, "/api/v1/servers/localhost/config", nil); response.Code != http.StatusTooManyRequests {
		t.Fatalf("throttled operator-only request = %d, want 429", response.Code)
	}
	app.denials.mu.Lock()
	defer app.denials.mu.Unlock()
	if app.denials.input.Action != "" {
		t.Fatalf("throttled request recorded an authorization denial: %+v", app.denials.input)
	}
}

func TestRateLimitMetersOperatorsAndSeparatesIdentities(t *testing.T) {
	limiter := newMemoryLimiter(t, `{"defaults": {"requests": {"capacity": 2, "refill_per_second": 0.001}}}`, io.Discard)
	app := newRateLimitApp(t, limiter, true)
	for range 2 {
		if response := app.do(http.MethodGet, "/api/v1/servers/localhost/zones", nil); response.Code != http.StatusOK {
			t.Fatalf("operator burst = %d", response.Code)
		}
	}
	if response := app.do(http.MethodGet, "/api/v1/servers/localhost/zones", nil); response.Code != http.StatusTooManyRequests {
		t.Fatalf("operator over burst = %d, want 429", response.Code)
	}
	if response := app.doAs(otherToken(), http.MethodGet, "/api/v1/servers/localhost/zones", nil); response.Code != http.StatusOK {
		t.Fatalf("separate identity = %d, want its own buckets", response.Code)
	}
}

func TestRateLimitFailsOpenAndStillRejectsImpossibleRequests(t *testing.T) {
	operations, err := ContractOperationIDs()
	if err != nil {
		t.Fatal(err)
	}
	table, _, err := ratelimit.ParsePolicy([]byte(`{"defaults": {"changes": {"capacity": 50}}}`), operations)
	if err != nil {
		t.Fatal(err)
	}
	logs := new(bytes.Buffer)
	limiter, err := ratelimit.NewLimiter(ratelimit.LimiterConfig{
		Table: table, Backend: failingRateBackend{}, Timeout: 25 * time.Millisecond,
		Reporter: ratelimit.NewReporter(slog.New(slog.NewJSONHandler(logs, nil)), time.Minute, nil),
	})
	if err != nil {
		t.Fatal(err)
	}
	app := newRateLimitApp(t, limiter, false)

	response := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, "REPLACE"))
	if response.Code != http.StatusNoContent || app.upstreamCalls.Load() != 1 {
		t.Fatalf("fail-open patch = %d, upstream calls %d", response.Code, app.upstreamCalls.Load())
	}
	if intents, _ := app.mutations.snapshot(); len(intents) != 1 {
		t.Fatal("fail-open patch skipped audit")
	}
	for _, header := range []string{"Retry-After", "X-DANS-RateLimit-Bucket"} {
		if _, ok := response.Header()[header]; ok {
			t.Errorf("fail-open response has %s", header)
		}
	}
	if !strings.Contains(logs.String(), ratelimit.EventFailOpen) || strings.Contains(logs.String(), "redis.internal") {
		t.Fatalf("fail-open logs = %s", logs)
	}

	impossible := app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, slices.Repeat([]string{"REPLACE"}, 30)...))
	if impossible.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("impossible request while backend is down = %d, want 413", impossible.Code)
	}
}

func TestRateLimitAccessLogFields(t *testing.T) {
	limiter := newMemoryLimiter(t, `{"defaults": {"changes": {"capacity": 4, "refill_per_second": 0.001}}}`, io.Discard)
	app := newRateLimitApp(t, limiter, false)

	app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, "REPLACE", "DELETE"))
	admitted := lastAccessLog(t, app.logs)
	if admitted["rate_limit"] != "admitted" || admitted["rate_limit_request_cost"] != float64(1) || admitted["rate_limit_change_cost"] != float64(3) {
		t.Fatalf("admitted log = %v", admitted)
	}
	if _, ok := admitted["rate_limit_ms"].(float64); !ok {
		t.Fatalf("limiter latency missing: %v", admitted)
	}

	app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, "REPLACE"))
	throttled := lastAccessLog(t, app.logs)
	if throttled["rate_limit"] != "throttled" || throttled["status"] != float64(http.StatusTooManyRequests) {
		t.Fatalf("throttled log = %v", throttled)
	}
	if buckets, _ := throttled["rate_limit_buckets"].([]any); len(buckets) != 1 || buckets[0] != "changes" {
		t.Fatalf("throttled buckets = %v", throttled["rate_limit_buckets"])
	}

	app.do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, slices.Repeat([]string{"DELETE"}, 5)...))
	if over := lastAccessLog(t, app.logs); over["rate_limit"] != "exceeds_capacity" {
		t.Fatalf("over-capacity log = %v", over)
	}

	app.doAs("", http.MethodGet, "/livez", nil)
	if anonymous := lastAccessLog(t, app.logs); anonymous["rate_limit"] != nil {
		t.Fatalf("anonymous request has rate-limit fields: %v", anonymous)
	}
	if strings.Contains(app.logs.String(), "192.0.2.1") || strings.Contains(app.logs.String(), validToken()) {
		t.Fatalf("access log contains a body or credential: %s", app.logs)
	}
}

func TestRateLimitUnmeteredRequestIsLogged(t *testing.T) {
	limiter := &fakeRateLimiter{decision: ratelimit.Decision{Outcome: ratelimit.OutcomeUnmetered, RequestCost: 1}}
	app := newRateLimitApp(t, limiter, false)
	app.do(http.MethodGet, "/api/v1/servers/localhost/zones", nil)
	if entry := lastAccessLog(t, app.logs); entry["rate_limit"] != "unmetered" {
		t.Fatalf("unmetered log = %v", entry)
	}
}

func TestContractOperationIDsAreCanonical(t *testing.T) {
	operations, err := ContractOperationIDs()
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"patchZone", "createZone", "deleteZone", "listZones", "getLiveness"} {
		if _, ok := operations[required]; !ok {
			t.Errorf("missing %s", required)
		}
	}
	for operation := range operations {
		if operation == "" || operation[0] < 'a' || operation[0] > 'z' {
			t.Errorf("operation ID %q is not canonical", operation)
		}
	}
}

func TestRateLimitDocsMatchResponses(t *testing.T) {
	docs, err := os.ReadFile(filepath.Join("..", "..", "docs", "api.md"))
	if err != nil {
		t.Fatal(err)
	}
	throttled := newRateLimitApp(t, &fakeRateLimiter{decision: ratelimit.Decision{
		Outcome: ratelimit.OutcomeThrottled, Short: []ratelimit.BucketName{ratelimit.BucketRequests, ratelimit.BucketOperation}, RetryAfter: 2100 * time.Millisecond,
	}}, false).do(http.MethodGet, "/api/v1/servers/localhost/zones", nil)
	capacity := newRateLimitApp(t, &fakeRateLimiter{decision: ratelimit.Decision{
		Outcome: ratelimit.OutcomeExceedsCapacity, Exceeded: []ratelimit.Exceeded{{Bucket: ratelimit.BucketChanges, Cost: 60, Capacity: 50}},
	}}, false).do(http.MethodPatch, "/api/v1/servers/localhost/zones/example.org.", zonePatch(t, "REPLACE"))
	for _, response := range []*httptest.ResponseRecorder{throttled, capacity} {
		wants := []string{
			fmt.Sprintf("HTTP/1.1 %d %s", response.Code, http.StatusText(response.Code)),
			"X-DANS-RateLimit-Bucket: " + response.Header().Get("X-DANS-RateLimit-Bucket"),
			strings.TrimSpace(response.Body.String()),
		}
		if retry := response.Header().Get("Retry-After"); retry != "" {
			wants = append(wants, "Retry-After: "+retry)
		}
		for _, want := range wants {
			if !strings.Contains(string(docs), want) {
				t.Errorf("docs/api.md does not show %q", want)
			}
		}
	}
}
