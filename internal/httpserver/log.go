package httpserver

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/ncode/dans/internal/ratelimit"
)

type contextKey uint8

const (
	requestIDKey contextKey = iota
	accessMetadataKey
	actorKey
	routeInfoKey
	reauthenticateKey
	exportParentKey
)

// AccessMetadata is populated by routing, authorization, and forwarding code.
// It intentionally has no free-form field or request/response payload field.
type AccessMetadata struct {
	routeTemplate   string
	apiOperationID  string
	actorID         string
	resourceID      string
	operationID     string
	upstreamOutcome string
	rateLimit       *ratelimit.Decision
}

func (metadata *AccessMetadata) SetRoute(template, apiOperationID string) {
	metadata.routeTemplate = template
	metadata.apiOperationID = apiOperationID
}

func (metadata *AccessMetadata) SetOpaqueIDs(actorID, resourceID, operationID string) {
	metadata.actorID = actorID
	metadata.resourceID = resourceID
	metadata.operationID = operationID
}

func (metadata *AccessMetadata) SetActorID(actorID string)       { metadata.actorID = actorID }
func (metadata *AccessMetadata) SetResourceID(resourceID string) { metadata.resourceID = resourceID }
func (metadata *AccessMetadata) SetOperationID(operationID string) {
	metadata.operationID = operationID
}

func (metadata *AccessMetadata) SetUpstreamOutcome(outcome string) {
	metadata.upstreamOutcome = outcome
}

// SetRateLimit records a metered request's rate-limit decision.
func (metadata *AccessMetadata) SetRateLimit(decision ratelimit.Decision) {
	metadata.rateLimit = &decision
}

// rateLimitAttributes are logged only for metered requests.
func (metadata *AccessMetadata) rateLimitAttributes() []any {
	decision := metadata.rateLimit
	if decision == nil {
		return nil
	}
	buckets := make([]string, 0, len(decision.Short)+len(decision.Exceeded))
	for _, bucket := range decision.Short {
		buckets = append(buckets, string(bucket))
	}
	for _, exceeded := range decision.Exceeded {
		buckets = append(buckets, string(exceeded.Bucket))
	}
	return []any{
		"rate_limit", string(decision.Outcome),
		"rate_limit_request_cost", decision.RequestCost,
		"rate_limit_change_cost", decision.ChangeCost,
		"rate_limit_buckets", buckets,
		"rate_limit_ms", float64(decision.Latency.Microseconds()) / 1000,
	}
}

// NewJSONLogger returns the sole production log encoding.
func NewJSONLogger(output io.Writer, level slog.Leveler) *slog.Logger {
	return slog.New(slog.NewJSONHandler(output, &slog.HandlerOptions{Level: level}))
}

// WithRequestID adds a generated opaque request identifier to request context.
func WithRequestID(ctx context.Context, requestID string) context.Context {
	return context.WithValue(ctx, requestIDKey, requestID)
}

// RequestIDFromContext returns the current request identifier, if assigned.
func RequestIDFromContext(ctx context.Context) string {
	requestID, _ := ctx.Value(requestIDKey).(string)
	return requestID
}

// AccessMetadataFromContext returns the request's bounded access-log fields.
func AccessMetadataFromContext(ctx context.Context) *AccessMetadata {
	metadata, _ := ctx.Value(accessMetadataKey).(*AccessMetadata)
	if metadata == nil {
		return &AccessMetadata{}
	}
	return metadata
}

// AccessLog emits exactly one structured access record after each request.
func AccessLog(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
			started := time.Now()
			metadata := &AccessMetadata{}
			request = request.WithContext(context.WithValue(request.Context(), accessMetadataKey, metadata))
			writer := &statusWriter{ResponseWriter: w}
			defer func() {
				status := writer.status
				if status == 0 {
					status = http.StatusOK
				}
				attributes := []any{
					"request_id", RequestIDFromContext(request.Context()),
					"method", request.Method,
					"route_template", metadata.routeTemplate,
					"api_operation_id", metadata.apiOperationID,
					"status", status,
					"duration_ms", time.Since(started).Milliseconds(),
					"actor_id", metadata.actorID,
					"resource_id", metadata.resourceID,
					"operation_id", metadata.operationID,
					"upstream_outcome", metadata.upstreamOutcome,
				}
				logger.InfoContext(request.Context(), "http request", append(attributes, metadata.rateLimitAttributes()...)...)
			}()
			next.ServeHTTP(writer, request)
		})
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (writer *statusWriter) WriteHeader(status int) {
	if writer.status != 0 {
		return
	}
	writer.status = status
	writer.ResponseWriter.WriteHeader(status)
}

func (writer *statusWriter) Write(value []byte) (int, error) {
	if writer.status == 0 {
		writer.WriteHeader(http.StatusOK)
	}
	return writer.ResponseWriter.Write(value)
}

// Unwrap lets http.ResponseController retain optional writer capabilities.
func (writer *statusWriter) Unwrap() http.ResponseWriter { return writer.ResponseWriter }
