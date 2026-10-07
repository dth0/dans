package httpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ncode/dans/api"
	contractdoc "github.com/ncode/dans/api/openapi"
	"github.com/ncode/dans/internal/database"
	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/ratelimit"
	"github.com/ncode/dans/internal/upstream"
)

const benchmarkZonePath = "/api/v1/servers/localhost/zones/example.org."

var benchmarkZoneResponse = []byte(`{"id":"example.org.","extension":"preserved"}`)

// Reuses the status/header writer while bounding retained body memory to one
// response. This intentionally has no ReaderFrom fast path.
type benchmarkCapture struct {
	benchmarkResponseWriter
	body bytes.Buffer
}

func (w *benchmarkCapture) Write(p []byte) (int, error) {
	w.benchmarkResponseWriter.Write(p)
	return w.body.Write(p)
}
func (w *benchmarkCapture) reset() { w.status = 0; clear(w.header); w.body.Reset() }

func benchmarkPatch(t testing.TB, size, records, contentBytes int) []byte {
	t.Helper()
	patch := api.ZonePatch{Rrsets: make([]api.RRSetChange, size)}
	for i := range patch.Rrsets {
		values := make([]api.Record, records)
		for j := range values {
			values[j] = api.Record{Content: "192.0.2.1", Disabled: new(false)}
			if contentBytes > 0 {
				values[j].Content = strings.Repeat("x", contentBytes)
			}
		}
		patch.Rrsets[i] = api.RRSetChange{Name: fmt.Sprintf("host-%d.example.org.", i), Type: "A", Changetype: "REPLACE", Ttl: new(300), Records: &values}
	}
	payload, err := json.Marshal(patch)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func benchmarkRequest(method string, payload []byte) *http.Request {
	request := httptest.NewRequest(method, benchmarkZonePath, nil)
	request.Header.Set("X-API-Key", validToken())
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
		request.ContentLength = int64(len(payload))
	}
	return request
}

func benchmarkServe(handler http.Handler, template *http.Request, payload []byte, writer *benchmarkCapture) {
	writer.reset()
	request := template.Clone(template.Context())
	if payload != nil {
		request.Body = io.NopCloser(bytes.NewReader(payload))
	}
	handler.ServeHTTP(writer, request)
}

func benchmarkResponseError(w *benchmarkCapture, status int) error {
	if w.status != status {
		return fmt.Errorf("response status = %d, want %d", w.status, status)
	}
	if w.header.Get("X-Request-ID") == "" || w.header.Get("Cache-Control") != "no-store" {
		return errors.New("missing response security headers")
	}
	switch status {
	case http.StatusOK:
		if !bytes.Equal(w.body.Bytes(), benchmarkZoneResponse) {
			return errors.New("read response changed")
		}
	case http.StatusNoContent:
		if w.body.Len() != 0 {
			return errors.New("nonempty mutation response")
		}
	case http.StatusForbidden:
		var response httpapi.ErrorResponse
		if err := json.Unmarshal(w.body.Bytes(), &response); err != nil {
			return err
		}
		if response.Error != "forbidden" || len(response.Errors) != 1 || response.Errors[0] != `rrsets[1]: owner="host-1.example.org." type="A" change="REPLACE"` {
			return errors.New("incorrect denied tuple")
		}
	}
	return nil
}

func benchmarkApplication(t testing.TB, config ApplicationConfig) http.Handler {
	t.Helper()
	health, err := NewHealth(passingDependencies(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	config.Boundary = BoundaryConfig{MaxBodyBytes: 1 << 20, RequestTimeout: 5 * time.Second, MaxConcurrent: 32}
	config.Logger = NewJSONLogger(io.Discard, slog.LevelInfo)
	config.Health = health
	config.PowerDNSReady = func() bool { return true }
	config.UpstreamID = "default"
	config.MutationTimeout = 5 * time.Second
	if config.DANS == nil {
		config.DANS = &testDANSHandler{}
	}
	if config.Lifecycle == nil {
		config.Lifecycle = &recordingZoneLifecycle{}
	}
	if config.Denials == nil {
		config.Denials = &recordingDenialAuditor{}
	}
	if config.AuditFailures == nil {
		config.AuditFailures = &recordingAuditFailureReporter{}
	}
	if config.LifecycleFailures == nil {
		config.LifecycleFailures = &recordingAuditFailureReporter{}
	}
	handler, err := NewApplicationHandler(config)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func benchmarkUpstream(t testing.TB) (*upstream.Client, *atomic.Int64) {
	t.Helper()
	calls := new(atomic.Int64)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if _, err := io.Copy(io.Discard, r.Body); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPatch {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		_, _ = w.Write(benchmarkZoneResponse)
	}))
	t.Cleanup(server.Close)
	client, err := upstream.New(upstream.TransportConfig{URL: server.URL, Timeout: 5 * time.Second}, httpapi.NewSecret("benchmark-key"))
	if err != nil {
		t.Fatal(err)
	}
	return client, calls
}

// The portable fixture retains only the latest intent and outcome.
type benchmarkMutationStore struct {
	decision          database.AuthorizationDecision
	intents, outcomes int
	lastIntent        database.DNSIntentInput
	lastOutcome       database.DNSOutcomeInput
}

func (s *benchmarkMutationStore) AuthorizeRRsetBatch(context.Context, string, string, string, string, []database.RRsetTuple) (database.AuthorizationDecision, error) {
	return s.decision, nil
}
func (s *benchmarkMutationStore) CreateDNSIntent(_ context.Context, _ database.Actor, input database.DNSIntentInput) (database.DNSIntent, error) {
	s.intents++
	s.lastIntent = input
	return database.DNSIntent{EventID: "00000000-0000-4000-8000-000000000010", OperationID: "00000000-0000-4000-8000-000000000011", Deadline: input.Deadline}, nil
}
func (s *benchmarkMutationStore) RecordDNSOutcome(_ context.Context, input database.DNSOutcomeInput) (database.DNSOutcome, error) {
	s.outcomes++
	s.lastOutcome = input
	return database.DNSOutcome{}, nil
}

func BenchmarkApplicationStubbed(b *testing.B) {
	for _, size := range []int{0, 1, 10, 100, -1} {
		name, method, status := "Read", http.MethodGet, http.StatusOK
		var payload []byte
		if size != 0 {
			name, method, status = "Patch"+strconv.Itoa(size), http.MethodPatch, http.StatusNoContent
			count := size
			if count < 0 {
				count = 2
			}
			payload = benchmarkPatch(b, count, 1, 0)
			if size < 0 {
				name, status = "Denied", http.StatusForbidden
			}
		}
		b.Run(name, func(b *testing.B) {
			client, calls := benchmarkUpstream(b)
			actor := database.Actor{IdentityID: "00000000-0000-4000-8000-000000000001", TokenID: "00000000-0000-4000-8000-000000000002", Kind: "service"}
			store := &benchmarkMutationStore{decision: database.AuthorizationDecision{Allowed: size >= 0, Actor: actor}}
			if size < 0 {
				store.decision.Denied = []database.DeniedRRsetTuple{{Index: 1, Owner: "host-1.example.org.", RecordType: "A", ChangeKind: "REPLACE"}}
			}
			handler := benchmarkApplication(b, ApplicationConfig{Upstream: client, Authenticator: authenticatorFunc(func(context.Context, string) (database.Actor, error) { return actor, nil }), Schema: func(context.Context) error { return nil }, Mutations: store})
			request := benchmarkRequest(method, payload)
			writer := benchmarkCapture{benchmarkResponseWriter: benchmarkResponseWriter{header: make(http.Header)}}
			invoke := func() {
				benchmarkServe(handler, request, payload, &writer)
				if err := benchmarkResponseError(&writer, status); err != nil {
					b.Fatal(err)
				}
			}
			invoke()
			warm := calls.Load()
			store.intents, store.outcomes = 0, 0
			b.ReportAllocs()
			if len(payload) > 0 {
				b.SetBytes(int64(len(payload)))
			}
			for b.Loop() {
				invoke()
			}
			wantCalls, wantAudits := int64(b.N), 0
			if size < 0 {
				wantCalls = 0
			}
			if size > 0 {
				wantAudits = b.N
			}
			if calls.Load()-warm != wantCalls || store.intents != wantAudits || store.outcomes != wantAudits {
				b.Fatal("incorrect upstream or audit count")
			}
			if size > 0 && (len(store.lastIntent.RRsets) != size || store.lastOutcome.Result != "succeeded" || store.lastOutcome.IntentEventID != "00000000-0000-4000-8000-000000000010") {
				b.Fatal("incorrect mutation audit")
			}
			if err := benchmarkResponseError(&writer, status); err != nil {
				b.Fatal(err)
			}
		})
	}
}

// BenchmarkApplicationStubbedRateLimited adds the rate-limit middleware to the
// stubbed application. Its limiter uses the in-memory backend (a stubbed
// dependency), so results exclude any Redis round trip and must not be read
// as deployed rate-limiting capacity.
func BenchmarkApplicationStubbedRateLimited(b *testing.B) {
	operations, err := ContractOperationIDs()
	if err != nil {
		b.Fatal(err)
	}
	table, _, err := ratelimit.ParsePolicy([]byte(`{"defaults": {
		"requests": {"capacity": 1000000000, "refill_per_second": 1000000000},
		"operations": {"*": {"capacity": 1000000000, "refill_per_second": 1000000000}},
		"changes": {"capacity": 1000000000, "refill_per_second": 1000000000}
	}}`), operations)
	if err != nil {
		b.Fatal(err)
	}
	for _, size := range []int{0, 1, 100} {
		name, method, status := "Read", http.MethodGet, http.StatusOK
		var payload []byte
		if size > 0 {
			name, method, status = "Patch"+strconv.Itoa(size), http.MethodPatch, http.StatusNoContent
			payload = benchmarkPatch(b, size, 1, 0)
		}
		b.Run(name, func(b *testing.B) {
			limiter, err := ratelimit.NewLimiter(ratelimit.LimiterConfig{
				Table: table, Backend: ratelimit.NewMemoryBackend(nil), Timeout: time.Second,
				Reporter: ratelimit.NewReporter(nil, 0, nil),
			})
			if err != nil {
				b.Fatal(err)
			}
			client, calls := benchmarkUpstream(b)
			actor := database.Actor{IdentityID: "00000000-0000-4000-8000-000000000001", TokenID: "00000000-0000-4000-8000-000000000002", Kind: "service"}
			store := &benchmarkMutationStore{decision: database.AuthorizationDecision{Allowed: true, Actor: actor}}
			handler := benchmarkApplication(b, ApplicationConfig{
				Upstream: client, Authenticator: authenticatorFunc(func(context.Context, string) (database.Actor, error) { return actor, nil }),
				Schema: func(context.Context) error { return nil }, Mutations: store, RateLimiter: limiter,
			})
			request := benchmarkRequest(method, payload)
			writer := benchmarkCapture{benchmarkResponseWriter: benchmarkResponseWriter{header: make(http.Header)}}
			invoke := func() {
				benchmarkServe(handler, request, payload, &writer)
				if err := benchmarkResponseError(&writer, status); err != nil {
					b.Fatal(err)
				}
				if _, limited := writer.header["X-Dans-Ratelimit-Bucket"]; limited {
					b.Fatal("benchmark request was throttled")
				}
			}
			invoke()
			warm := calls.Load()
			b.ReportAllocs()
			if len(payload) > 0 {
				b.SetBytes(int64(len(payload)))
			}
			for b.Loop() {
				invoke()
			}
			if calls.Load()-warm != int64(b.N) {
				b.Fatal("incorrect upstream count")
			}
		})
	}
}

func BenchmarkContractValidation(b *testing.B) {
	base := benchmarkPatch(b, 100, 1, 0)
	for _, test := range []struct {
		name    string
		payload []byte
		status  int
	}{
		{"Read", nil, http.StatusNoContent},
		{"Patch1", benchmarkPatch(b, 1, 1, 0), http.StatusNoContent},
		{"Patch10", benchmarkPatch(b, 10, 1, 0), http.StatusNoContent},
		{"Patch100", base, http.StatusNoContent},
		{"NearLimit", benchmarkPatch(b, 1, 16, 60000), http.StatusNoContent},
		{"LateDuplicate", append(bytes.Clone(base[:len(base)-1]), []byte(`,"rrsets":[]}`)...), http.StatusBadRequest},
		{"LateUnknown", append(bytes.Clone(base[:len(base)-1]), []byte(`,"unexpected":true}`)...), http.StatusUnprocessableEntity},
	} {
		b.Run(test.name, func(b *testing.B) {
			document, err := contractdoc.Spec()
			if err != nil {
				b.Fatal(err)
			}
			validation, err := NewContractValidation(document)
			if err != nil {
				b.Fatal(err)
			}
			calls := 0
			handler := validation(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { calls++; w.WriteHeader(http.StatusNoContent) }))
			method := http.MethodPatch
			if test.payload == nil {
				method = http.MethodGet
			}
			request := benchmarkRequest(method, test.payload)
			writer := benchmarkCapture{benchmarkResponseWriter: benchmarkResponseWriter{header: make(http.Header)}}
			b.ReportAllocs()
			if test.payload != nil {
				b.SetBytes(int64(len(test.payload)))
			}
			for b.Loop() {
				benchmarkServe(handler, request, test.payload, &writer)
				if writer.status != test.status {
					b.Fatalf("status = %d, want %d", writer.status, test.status)
				}
			}
			want := 0
			if test.status == http.StatusNoContent {
				want = b.N
			}
			if calls != want {
				b.Fatal("invalid terminal-handler count")
			}
		})
	}
}
