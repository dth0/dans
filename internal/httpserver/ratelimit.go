package httpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/ncode/dans/internal/database"
	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/ratelimit"
)

// RateLimitBucketHeader names every bucket that refused a request.
const RateLimitBucketHeader = "X-DANS-RateLimit-Bucket"

// RateLimiter meters one authenticated request. It never fails: backend
// errors produce an unmetered decision.
type RateLimiter interface {
	Admit(context.Context, ratelimit.Request) ratelimit.Decision
}

// RateLimit meters authenticated requests after authentication and before
// compatibility, authorization, audit, and forwarding. Anonymous requests
// pass through. Admitted and unmetered requests gain no headers.
func RateLimit(limiter RateLimiter) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
			actor, authenticated := ActorFromContext(request.Context())
			route, routed := RouteInfoFromContext(request.Context())
			if !authenticated || !routed {
				next.ServeHTTP(w, request)
				return
			}
			AccessMetadataFromContext(request.Context()).SetActorID(actor.IdentityID)
			meter := ratelimit.Request{IdentityID: actor.IdentityID, Operation: route.OperationID}
			if route.OperationID == ratelimit.PatchZoneOperation {
				kinds, err := patchChangeKinds(request)
				if err != nil {
					httpapi.WriteError(w, RequestIDFromContext(request.Context()), httpapi.NewError(httpapi.KindBadRequest, err))
					return
				}
				meter.ChangeKinds = kinds
			}

			decision := limiter.Admit(request.Context(), meter)
			AccessMetadataFromContext(request.Context()).SetRateLimit(decision)
			switch decision.Outcome {
			case ratelimit.OutcomeThrottled:
				details := make([]string, len(decision.Short))
				for index, bucket := range decision.Short {
					details[index] = "bucket: " + string(bucket)
				}
				w.Header().Set(RateLimitBucketHeader, joinBuckets(decision.Short))
				w.Header().Set("Retry-After", strconv.FormatInt(ratelimit.RetryAfterSeconds(decision.RetryAfter), 10))
				httpapi.WriteError(w, RequestIDFromContext(request.Context()),
					httpapi.NewDetailedError(httpapi.KindRateLimited, errors.New("rate-limit bucket lacks tokens"), details...))
				return
			case ratelimit.OutcomeExceedsCapacity:
				buckets := make([]ratelimit.BucketName, len(decision.Exceeded))
				details := make([]string, 0, 3*len(decision.Exceeded))
				for index, exceeded := range decision.Exceeded {
					buckets[index] = exceeded.Bucket
					details = append(details,
						"bucket: "+string(exceeded.Bucket),
						fmt.Sprintf("cost: %d", exceeded.Cost),
						fmt.Sprintf("capacity: %d", exceeded.Capacity))
				}
				w.Header().Set(RateLimitBucketHeader, joinBuckets(buckets))
				httpapi.WriteError(w, RequestIDFromContext(request.Context()),
					httpapi.NewDetailedError(httpapi.KindRateLimitCapacity, errors.New("request cost exceeds rate-limit capacity"), details...))
				return
			}
			next.ServeHTTP(w, request)
		})
	}
}

// patchChangeKinds reads the change kind of each RRset in a buffered zone
// PATCH body and restores the body for the handler. Batches outside the
// supported size are not charged; the handler rejects them with 422.
func patchChangeKinds(request *http.Request) ([]string, error) {
	if request.Body == nil {
		return nil, nil
	}
	body, err := io.ReadAll(request.Body)
	closeErr := request.Body.Close()
	if err := errors.Join(err, closeErr); err != nil {
		return nil, fmt.Errorf("read zone patch: %w", err)
	}
	request.Body = io.NopCloser(bytes.NewReader(body))
	var patch struct {
		RRsets []struct {
			Changetype string `json:"changetype"`
		} `json:"rrsets"`
	}
	if err := json.Unmarshal(body, &patch); err != nil {
		return nil, nil
	}
	if len(patch.RRsets) == 0 || len(patch.RRsets) > database.MaxRRsetBatch {
		return nil, nil
	}
	kinds := make([]string, len(patch.RRsets))
	for index, rrset := range patch.RRsets {
		kinds[index] = rrset.Changetype
	}
	return kinds, nil
}

func joinBuckets(buckets []ratelimit.BucketName) string {
	names := make([]string, len(buckets))
	for index, bucket := range buckets {
		names[index] = string(bucket)
	}
	return strings.Join(names, ", ")
}
