package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ncode/dans/internal/identifier"
)

func TestErrorMappingIsStable(t *testing.T) {
	t.Parallel()

	tests := []struct {
		kind    ErrorKind
		status  int
		message string
	}{
		{KindBadRequest, http.StatusBadRequest, "bad request"},
		{KindInvalidRequest, http.StatusUnprocessableEntity, "unprocessable entity"},
		{KindUnauthenticated, http.StatusUnauthorized, "unauthorized"},
		{KindForbidden, http.StatusForbidden, "forbidden"},
		{KindNotFound, http.StatusNotFound, "not found"},
		{KindConflict, http.StatusConflict, "conflict"},
		{KindBodyTooLarge, http.StatusRequestEntityTooLarge, "request body too large"},
		{KindRateLimited, http.StatusTooManyRequests, "Rate exceeded"},
		{KindRateLimitCapacity, http.StatusRequestEntityTooLarge, "request cost exceeds rate-limit capacity"},
		{KindUnavailable, http.StatusServiceUnavailable, "service unavailable"},
		{KindBadGateway, http.StatusBadGateway, "bad gateway"},
		{KindGatewayTimeout, http.StatusGatewayTimeout, "gateway timeout"},
		{KindInternal, http.StatusInternalServerError, "internal server error"},
	}
	for _, tt := range tests {
		t.Run(string(tt.kind), func(t *testing.T) {
			t.Parallel()
			err := NewError(tt.kind, errors.New("database target and secret"))
			if got := StatusCode(err); got != tt.status {
				t.Errorf("StatusCode(%q) = %d, want %d", tt.kind, got, tt.status)
			}
			body := ErrorBody(err)
			if body.Error != tt.message {
				t.Errorf("ErrorBody(%q).Error = %q, want %q", tt.kind, body.Error, tt.message)
			}
			if strings.Contains(body.Error, "database") || strings.Contains(body.Error, "secret") {
				t.Errorf("ErrorBody(%q) exposed internal cause: %q", tt.kind, body.Error)
			}
		})
	}
}

func TestRateLimitErrorsCarryPublicDetails(t *testing.T) {
	t.Parallel()

	err := NewDetailedError(KindRateLimitCapacity, errors.New("policy for identity"), "bucket: changes", "cost: 60", "capacity: 50")
	body := ErrorBody(err)
	if StatusCode(err) != http.StatusRequestEntityTooLarge || body.Error != "request cost exceeds rate-limit capacity" {
		t.Fatalf("capacity error = %d %+v", StatusCode(err), body)
	}
	if strings.Join(body.Errors, ",") != "bucket: changes,cost: 60,capacity: 50" {
		t.Fatalf("details = %v", body.Errors)
	}
	if body := ErrorBody(NewError(KindBodyTooLarge, nil)); body.Error == ErrorBody(err).Error {
		t.Fatal("capacity rejection is indistinguishable from an oversized body")
	}
}

func TestErrorMappingHandlesWrappingAndUnknownErrors(t *testing.T) {
	t.Parallel()

	err := fmt.Errorf("authorize request: %w", NewError(KindForbidden, errors.New("policy row 7")))
	if got := StatusCode(err); got != http.StatusForbidden {
		t.Errorf("StatusCode(wrapped error) = %d, want %d", got, http.StatusForbidden)
	}
	if got := StatusCode(errors.New("unclassified")); got != http.StatusInternalServerError {
		t.Errorf("StatusCode(unknown error) = %d, want %d", got, http.StatusInternalServerError)
	}
	if got := ErrorBody(errors.New("unclassified")).Error; got != "internal server error" {
		t.Errorf("ErrorBody(unknown).Error = %q", got)
	}
}

func TestUnauthenticatedErrorShapeIsUniform(t *testing.T) {
	t.Parallel()

	causes := []error{
		errors.New("missing header"),
		errors.New("duplicate header"),
		errors.New("malformed token"),
		errors.New("unknown token"),
		errors.New("expired token"),
		errors.New("disabled identity"),
	}
	var want []byte
	for _, cause := range causes {
		recorder := httptest.NewRecorder()
		WriteError(recorder, "00000000-0000-4000-8000-000000000000", NewError(KindUnauthenticated, cause))
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("WriteError(%v) status = %d", cause, recorder.Code)
		}
		if want == nil {
			want = bytes.Clone(recorder.Body.Bytes())
		} else if !bytes.Equal(recorder.Body.Bytes(), want) {
			t.Errorf("WriteError(%v) body = %q, want uniform %q", cause, recorder.Body.Bytes(), want)
		}
	}
}

func TestWriteErrorSetsSecurityAndTracingHeaders(t *testing.T) {
	t.Parallel()

	recorder := httptest.NewRecorder()
	requestID := "00000000-0000-4000-8000-000000000000"
	WriteError(recorder, requestID, NewDetailedError(KindInvalidRequest, nil, "field is required"))
	if recorder.Code != http.StatusUnprocessableEntity {
		t.Errorf("status = %d, want %d", recorder.Code, http.StatusUnprocessableEntity)
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
	if got := recorder.Header().Get("X-Request-ID"); got != requestID {
		t.Errorf("X-Request-ID = %q, want %q", got, requestID)
	}
	var body ErrorResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Error != "unprocessable entity" || len(body.Errors) != 1 || body.Errors[0] != "field is required" {
		t.Errorf("body = %+v", body)
	}
}

func TestNewRequestIDProducesUUIDv4(t *testing.T) {
	t.Parallel()

	first, err := NewRequestID()
	if err != nil {
		t.Fatalf("NewRequestID: %v", err)
	}
	second, err := NewRequestID()
	if err != nil {
		t.Fatalf("NewRequestID second: %v", err)
	}
	if err := identifier.ValidateUUID(first); err != nil {
		t.Errorf("NewRequestID() = %q: %v", first, err)
	}
	if first == second {
		t.Errorf("two request IDs are equal: %q", first)
	}
}

func TestSecretIsRedactedByDiagnosticFormats(t *testing.T) {
	t.Parallel()

	secret := NewSecret("upstream-super-secret")
	outputs := []string{
		fmt.Sprint(secret),
		fmt.Sprintf("%q", secret),
		string(mustJSON(t, secret)),
	}
	var log bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&log, nil))
	logger.Info("configured", "key", secret)
	outputs = append(outputs, log.String())
	for _, output := range outputs {
		if strings.Contains(output, secret.Value()) {
			t.Errorf("diagnostic output exposed secret: %q", output)
		}
		if !strings.Contains(output, Redacted) {
			t.Errorf("diagnostic output %q lacks redaction marker", output)
		}
	}
}

func TestRedactTextRemovesKnownSecretsAndDANSTokens(t *testing.T) {
	t.Parallel()

	token := identifier.TokenPrefix + strings.Repeat("A", 43)
	got := RedactText("upstream=power-key token="+token, NewSecret("power-key"))
	if strings.Contains(got, "power-key") || strings.Contains(got, token) {
		t.Errorf("RedactText exposed secret: %q", got)
	}
	if strings.Count(got, Redacted) != 2 {
		t.Errorf("RedactText() = %q, want two redactions", got)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	return data
}

func TestRedactTextRemovesBrowserSessionsAndKeepsIncompletePrefixesSafe(t *testing.T) {
	t.Parallel()
	const secret = "session_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	if got := RedactText("session=" + secret); got != "session="+Redacted {
		t.Errorf("browser secret was not redacted")
	}
	for _, prefix := range []string{"dans_v1_", "session_v1_"} {
		input := strings.Repeat("x", 80) + prefix
		if got := RedactText(input); got != input {
			t.Errorf("incomplete credential changed")
		}
	}
}
