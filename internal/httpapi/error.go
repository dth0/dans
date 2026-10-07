// Package httpapi contains HTTP trust-boundary primitives shared by handlers.
package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/ncode/dans/internal/identifier"
)

const Redacted = "[REDACTED]"

// ErrorKind is a stable class of DANS-originated failure.
type ErrorKind string

const (
	KindBadRequest      ErrorKind = "bad_request"
	KindInvalidRequest  ErrorKind = "invalid_request"
	KindUnauthenticated ErrorKind = "unauthenticated"
	KindForbidden       ErrorKind = "forbidden"
	KindNotFound        ErrorKind = "not_found"
	KindConflict        ErrorKind = "conflict"
	KindBodyTooLarge    ErrorKind = "body_too_large"
	// KindRateLimited is a retryable throttle: a bucket lacks tokens now.
	KindRateLimited ErrorKind = "rate_limited"
	// KindRateLimitCapacity is not retryable: the request cost exceeds a
	// bucket's capacity, so it can never be admitted as sent.
	KindRateLimitCapacity ErrorKind = "rate_limit_capacity"
	KindUnavailable       ErrorKind = "unavailable"
	KindBadGateway        ErrorKind = "bad_gateway"
	KindGatewayTimeout    ErrorKind = "gateway_timeout"
	KindInternal          ErrorKind = "internal"
)

// ErrorResponse is the PowerDNS-compatible body for a DANS-originated error.
type ErrorResponse struct {
	Error  string   `json:"error"`
	Errors []string `json:"errors,omitzero"`
}

// APIError retains an internal cause while exposing only a stable public kind.
type APIError struct {
	cause   error
	kind    ErrorKind
	details []string
}

// NewError classifies cause without exposing its text to clients.
func NewError(kind ErrorKind, cause error) *APIError {
	return &APIError{kind: kind, cause: cause}
}

// NewDetailedError adds already-sanitized public validation details.
func NewDetailedError(kind ErrorKind, cause error, details ...string) *APIError {
	return &APIError{kind: kind, cause: cause, details: append([]string(nil), details...)}
}

func (e *APIError) Error() string {
	if e == nil {
		return publicMessage(KindInternal)
	}
	return publicMessage(e.kind)
}

// Unwrap preserves the internal cause for server-side inspection.
func (e *APIError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.cause
}

// StatusCode maps a classified error to its stable HTTP status.
func StatusCode(err error) int {
	if apiErr, ok := errors.AsType[*APIError](err); ok {
		return statusFor(apiErr.kind)
	}
	return http.StatusInternalServerError
}

// ErrorBody maps a classified error to a secret-safe public response.
func ErrorBody(err error) ErrorResponse {
	if apiErr, ok := errors.AsType[*APIError](err); ok {
		return ErrorResponse{
			Error:  publicMessage(apiErr.kind),
			Errors: append([]string(nil), apiErr.details...),
		}
	}
	return ErrorResponse{Error: publicMessage(KindInternal)}
}

// WriteError emits one deterministic DANS error response.
func WriteError(w http.ResponseWriter, requestID string, err error) {
	payload, marshalErr := json.Marshal(ErrorBody(err))
	if marshalErr != nil {
		payload = []byte(`{"error":"internal server error"}`)
		err = NewError(KindInternal, marshalErr)
	}
	payload = append(payload, '\n')
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Request-ID", requestID)
	w.WriteHeader(StatusCode(err))
	_, _ = w.Write(payload) // The connection owns response-write failures after headers are committed.
}

// NewRequestID returns a cryptographically random lowercase UUIDv4.
func NewRequestID() (string, error) { return identifier.NewUUID() }

func statusFor(kind ErrorKind) int {
	switch kind {
	case KindBadRequest:
		return http.StatusBadRequest
	case KindInvalidRequest:
		return http.StatusUnprocessableEntity
	case KindUnauthenticated:
		return http.StatusUnauthorized
	case KindForbidden:
		return http.StatusForbidden
	case KindNotFound:
		return http.StatusNotFound
	case KindConflict:
		return http.StatusConflict
	case KindBodyTooLarge, KindRateLimitCapacity:
		return http.StatusRequestEntityTooLarge
	case KindRateLimited:
		return http.StatusTooManyRequests
	case KindUnavailable:
		return http.StatusServiceUnavailable
	case KindBadGateway:
		return http.StatusBadGateway
	case KindGatewayTimeout:
		return http.StatusGatewayTimeout
	default:
		return http.StatusInternalServerError
	}
}

func publicMessage(kind ErrorKind) string {
	switch kind {
	case KindBadRequest:
		return "bad request"
	case KindInvalidRequest:
		return "unprocessable entity"
	case KindUnauthenticated:
		return "unauthorized"
	case KindForbidden:
		return "forbidden"
	case KindNotFound:
		return "not found"
	case KindConflict:
		return "conflict"
	case KindBodyTooLarge:
		return "request body too large"
	case KindRateLimited:
		return "Rate exceeded"
	case KindRateLimitCapacity:
		return "request cost exceeds rate-limit capacity"
	case KindUnavailable:
		return "service unavailable"
	case KindBadGateway:
		return "bad gateway"
	case KindGatewayTimeout:
		return "gateway timeout"
	default:
		return "internal server error"
	}
}

// Secret wraps a value so common diagnostic encoders redact it by default.
type Secret struct{ value string }

// NewSecret marks value as secret-bearing data.
func NewSecret(value string) Secret { return Secret{value: value} }

// Value explicitly unwraps a secret for its intended protocol use.
func (s Secret) Value() string { return s.value }

func (Secret) String() string   { return Redacted }
func (Secret) GoString() string { return Redacted }

// LogValue prevents structured slog handlers from recording the value.
func (Secret) LogValue() slog.Value { return slog.StringValue(Redacted) }

// MarshalJSON prevents accidental secret disclosure in JSON diagnostics.
func (Secret) MarshalJSON() ([]byte, error) { return json.Marshal(Redacted) }

// RedactText removes explicit secret values and supported token/session syntax.
func RedactText(text string, secrets ...Secret) string {
	for _, secret := range secrets {
		if secret.value != "" {
			text = strings.ReplaceAll(text, secret.value, Redacted)
		}
	}
	for _, prefix := range []string{identifier.TokenPrefix, "session_v1_"} {
		credentialLength := len(prefix) + 43
		for start := 0; start+credentialLength <= len(text); {
			offset := strings.Index(text[start:], prefix)
			if offset < 0 {
				break
			}
			offset += start
			if offset+credentialLength > len(text) {
				break
			}
			candidate := text[offset : offset+credentialLength]
			if identifier.ValidateToken(identifier.TokenPrefix+candidate[len(prefix):]) == nil {
				text = text[:offset] + Redacted + text[offset+credentialLength:]
				start = offset + len(Redacted)
				continue
			}
			start = offset + len(prefix)
		}
	}
	return text
}
