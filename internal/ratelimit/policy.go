// Package ratelimit meters identity request rate and DNS change throughput
// with Route 53-style token buckets shared by every API instance.
package ratelimit

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math"
	"slices"
	"strings"
	"time"

	"github.com/ncode/dans/internal/httpapi"
	"github.com/ncode/dans/internal/identifier"
)

// Built-in defaults mirror "Throttling for Amazon Route 53 API requests"
// (https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/throttling-api-requests.html),
// verified on 2026-10-06. AWS has changed these limits before, so re-check the
// page before changing them. Only operations DANS exposes are listed:
// createZone mirrors CreateHostedZone, deleteZone mirrors DeleteHostedZone,
// and zone PATCH change kinds mirror ChangeResourceRecordSets (REPLACE as
// UPSERT; EXTEND and PRUNE as single-value CREATE/DELETE equivalents).
const (
	// DefaultOperationKey names the bucket for operations without their own entry.
	DefaultOperationKey = "*"
	// PatchZoneOperation is charged by change kind rather than a flat cost.
	PatchZoneOperation = "patchZone"
	// MaxBatchRRsets is the largest zone PATCH batch DANS accepts.
	MaxBatchRRsets = 100

	maxCapacity       = 1_000_000_000
	maxRefill         = 1_000_000_000
	maxCost           = 1_000_000
	maxPolicyFileSize = 4 << 20
	// Leave room for millisecond rounding and the extra expiry second.
	maxFullRefillMillis = (math.MaxInt64 - int64(time.Second)) / int64(time.Millisecond)
)

// ChangeKinds are the zone PATCH change types DANS forwards.
var ChangeKinds = []string{"REPLACE", "DELETE", "EXTEND", "PRUNE"}

// Bucket is one token bucket's burst capacity and sustained refill rate.
type Bucket struct {
	Capacity        int64
	RefillPerSecond float64
}

// Policy is the fully resolved set of limits for one identity.
type Policy struct {
	Requests         Bucket
	DefaultOperation Bucket
	Operations       map[string]Bucket
	Changes          Bucket
	ChangeCosts      map[string]int64
	OperationCosts   map[string]int64
}

// BuiltinPolicy returns an independent copy of the Route 53-derived defaults.
func BuiltinPolicy() Policy {
	return Policy{
		Requests:         Bucket{Capacity: 50, RefillPerSecond: 10},
		DefaultOperation: Bucket{Capacity: 50, RefillPerSecond: 10},
		Operations: map[string]Bucket{
			"createZone": {Capacity: 40, RefillPerSecond: 2},
			"deleteZone": {Capacity: 40, RefillPerSecond: 5},
		},
		Changes:        Bucket{Capacity: 1500, RefillPerSecond: 100},
		ChangeCosts:    map[string]int64{"REPLACE": 2, "DELETE": 1, "EXTEND": 1, "PRUNE": 1},
		OperationCosts: map[string]int64{"createZone": 2, "deleteZone": 2},
	}
}

// OperationBucket returns the request bucket for an operation ID.
func (policy Policy) OperationBucket(operation string) Bucket {
	if bucket, ok := policy.Operations[operation]; ok {
		return bucket
	}
	return policy.DefaultOperation
}

// ChangeCost returns the change-throughput cost of one request.
func (policy Policy) ChangeCost(operation string, changeKinds []string) int64 {
	if operation != PatchZoneOperation {
		return policy.OperationCosts[operation]
	}
	var total int64
	for _, kind := range changeKinds {
		cost, ok := policy.ChangeCosts[kind]
		if !ok {
			cost = policy.maxChangeKindCost()
		}
		total += cost
	}
	return total
}

// MaxRequestChangeCost is the largest change cost one request can have.
func (policy Policy) MaxRequestChangeCost() int64 {
	largest := policy.maxChangeKindCost() * MaxBatchRRsets
	for _, cost := range policy.OperationCosts {
		largest = max(largest, cost)
	}
	return largest
}

func (policy Policy) maxChangeKindCost() int64 {
	var largest int64
	for _, cost := range policy.ChangeCosts {
		largest = max(largest, cost)
	}
	return largest
}

func (policy Policy) clone() Policy {
	policy.Operations = maps.Clone(policy.Operations)
	policy.ChangeCosts = maps.Clone(policy.ChangeCosts)
	policy.OperationCosts = maps.Clone(policy.OperationCosts)
	return policy
}

// Table resolves the immutable policy for every identity.
type Table struct {
	defaults   Policy
	identities map[string]Policy
}

// NewBuiltinTable returns a table that applies built-in defaults to everyone.
func NewBuiltinTable() *Table {
	return &Table{defaults: BuiltinPolicy()}
}

// For returns the policy for an identity resource ID.
func (table *Table) For(identityID string) Policy {
	if policy, ok := table.identities[identityID]; ok {
		return policy
	}
	return table.defaults
}

// Document is the strict JSON rate-limit policy file.
type Document struct {
	Defaults   *Override           `json:"defaults"`
	Identities map[string]Override `json:"identities"`
}

// Override sets any subset of a policy's values; omitted values are inherited.
type Override struct {
	Requests       *BucketOverride           `json:"requests"`
	Operations     map[string]BucketOverride `json:"operations"`
	Changes        *BucketOverride           `json:"changes"`
	ChangeCosts    costOverrides             `json:"change_costs"`
	OperationCosts costOverrides             `json:"operation_costs"`
}

// costOverrides preserves explicit zero costs while rejecting JSON null entries.
type costOverrides map[string]int64

func (costs *costOverrides) UnmarshalJSON(data []byte) error {
	var values map[string]*int64
	if err := json.Unmarshal(data, &values); err != nil {
		return err
	}
	if values == nil {
		*costs = nil
		return nil
	}
	decoded := make(costOverrides, len(values))
	for _, key := range slices.Sorted(maps.Keys(values)) {
		if values[key] == nil {
			return fmt.Errorf("cost %q must be a non-null integer", key)
		}
		decoded[key] = *values[key]
	}
	*costs = decoded
	return nil
}

// BucketOverride sets either or both bucket values.
type BucketOverride struct {
	Capacity        *int64   `json:"capacity"`
	RefillPerSecond *float64 `json:"refill_per_second"`
}

// ParsePolicy strictly decodes and validates a policy document. operations is
// the set of contract operation IDs a policy may name. It returns the
// resolved table and warnings for capacities that some request can never fit.
func ParsePolicy(data []byte, operations map[string]struct{}) (*Table, []string, error) {
	if len(data) > maxPolicyFileSize {
		return nil, nil, fmt.Errorf("policy exceeds %d bytes", maxPolicyFileSize)
	}
	var document Document
	err := httpapi.StrictJSON(bytes.NewReader(data), maxPolicyFileSize, func(decoded Document) error {
		document = decoded
		return nil
	})
	if err != nil {
		if cause := errors.Unwrap(err); cause != nil {
			return nil, nil, fmt.Errorf("decode policy as strict JSON: %w", cause)
		}
		return nil, nil, fmt.Errorf("decode policy as strict JSON: %w", err)
	}
	return document.Resolve(operations)
}

// Resolve validates the document and applies identity > defaults > built-in
// precedence field by field.
func (document Document) Resolve(operations map[string]struct{}) (*Table, []string, error) {
	defaults := BuiltinPolicy()
	if document.Defaults != nil {
		if err := document.Defaults.validate(operations); err != nil {
			return nil, nil, fmt.Errorf("defaults: %w", err)
		}
		defaults = document.Defaults.apply(defaults)
	}
	if err := defaults.validateDurations(); err != nil {
		return nil, nil, fmt.Errorf("defaults: %w", err)
	}
	table := &Table{defaults: defaults, identities: make(map[string]Policy, len(document.Identities))}
	var warnings []string
	if warning := capacityWarning("defaults", defaults); warning != "" {
		warnings = append(warnings, warning)
	}
	for _, identityID := range slices.Sorted(maps.Keys(document.Identities)) {
		if identifier.ValidateUUID(identityID) != nil {
			return nil, nil, fmt.Errorf("identities: key %q must be a lowercase UUIDv4 identity resource ID", identityID)
		}
		override := document.Identities[identityID]
		if err := override.validate(operations); err != nil {
			return nil, nil, fmt.Errorf("identities.%s: %w", identityID, err)
		}
		policy := override.apply(defaults)
		if err := policy.validateDurations(); err != nil {
			return nil, nil, fmt.Errorf("identities.%s: %w", identityID, err)
		}
		table.identities[identityID] = policy
		if warning := capacityWarning("identity "+identityID, policy); warning != "" {
			warnings = append(warnings, warning)
		}
	}
	return table, warnings, nil
}

func (policy Policy) validateDurations() error {
	for _, entry := range []struct {
		name   string
		bucket Bucket
	}{
		{"requests", policy.Requests},
		{"operations.*", policy.DefaultOperation},
		{"changes", policy.Changes},
	} {
		if err := entry.bucket.validateDuration(); err != nil {
			return fmt.Errorf("%s: %w", entry.name, err)
		}
	}
	for _, operation := range slices.Sorted(maps.Keys(policy.Operations)) {
		if err := policy.Operations[operation].validateDuration(); err != nil {
			return fmt.Errorf("operations.%s: %w", operation, err)
		}
	}
	return nil
}

func (bucket Bucket) validateDuration() error {
	// Costs that fit a bucket cannot wait longer than its full-refill time.
	milliseconds := math.Ceil(float64(bucket.Capacity) / bucket.RefillPerSecond * 1000)
	if milliseconds > float64(maxFullRefillMillis) {
		return errors.New("full-refill time plus 1s must fit in a time.Duration")
	}
	return nil
}

func capacityWarning(scope string, policy Policy) string {
	largest := policy.MaxRequestChangeCost()
	if policy.Changes.Capacity >= largest {
		return ""
	}
	return fmt.Sprintf("rate-limit %s: change capacity %d is below the largest possible request change cost %d; such requests are rejected with 413",
		scope, policy.Changes.Capacity, largest)
}

func (override Override) validate(operations map[string]struct{}) error {
	if override.Requests != nil {
		if err := override.Requests.validate(); err != nil {
			return fmt.Errorf("requests: %w", err)
		}
	}
	if override.Changes != nil {
		if err := override.Changes.validate(); err != nil {
			return fmt.Errorf("changes: %w", err)
		}
	}
	for _, operation := range slices.Sorted(maps.Keys(override.Operations)) {
		if _, ok := operations[operation]; !ok && operation != DefaultOperationKey {
			return fmt.Errorf("operations: unknown operation ID %q", operation)
		}
		bucket := override.Operations[operation]
		if err := bucket.validate(); err != nil {
			return fmt.Errorf("operations.%s: %w", operation, err)
		}
	}
	for _, kind := range slices.Sorted(maps.Keys(override.ChangeCosts)) {
		if !slices.Contains(ChangeKinds, kind) {
			return fmt.Errorf("change_costs: unknown change kind %q (want one of %s)", kind, strings.Join(ChangeKinds, ", "))
		}
		if err := validateCost(override.ChangeCosts[kind]); err != nil {
			return fmt.Errorf("change_costs.%s: %w", kind, err)
		}
	}
	for _, operation := range slices.Sorted(maps.Keys(override.OperationCosts)) {
		if operation == PatchZoneOperation {
			return errors.New("operation_costs: patchZone is charged only through change_costs")
		}
		if _, ok := operations[operation]; !ok {
			return fmt.Errorf("operation_costs: unknown operation ID %q", operation)
		}
		if err := validateCost(override.OperationCosts[operation]); err != nil {
			return fmt.Errorf("operation_costs.%s: %w", operation, err)
		}
	}
	return nil
}

func (override BucketOverride) validate() error {
	if override.Capacity == nil && override.RefillPerSecond == nil {
		return errors.New("must set capacity or refill_per_second")
	}
	if override.Capacity != nil && (*override.Capacity < 1 || *override.Capacity > maxCapacity) {
		return fmt.Errorf("capacity must be an integer from 1 through %d", maxCapacity)
	}
	if override.RefillPerSecond != nil {
		refill := *override.RefillPerSecond
		if math.IsNaN(refill) || math.IsInf(refill, 0) || refill <= 0 || refill > maxRefill {
			return fmt.Errorf("refill_per_second must be greater than 0 and at most %d", maxRefill)
		}
	}
	return nil
}

func validateCost(cost int64) error {
	if cost < 0 || cost > maxCost {
		return fmt.Errorf("cost must be an integer from 0 through %d", maxCost)
	}
	return nil
}

func (override Override) apply(base Policy) Policy {
	policy := base.clone()
	if override.Requests != nil {
		policy.Requests = override.Requests.apply(policy.Requests)
	}
	if override.Changes != nil {
		policy.Changes = override.Changes.apply(policy.Changes)
	}
	if bucket, ok := override.Operations[DefaultOperationKey]; ok {
		policy.DefaultOperation = bucket.apply(policy.DefaultOperation)
	}
	for operation, bucket := range override.Operations {
		if operation == DefaultOperationKey {
			continue
		}
		policy.Operations[operation] = bucket.apply(policy.OperationBucket(operation))
	}
	maps.Copy(policy.ChangeCosts, override.ChangeCosts)
	maps.Copy(policy.OperationCosts, override.OperationCosts)
	return policy
}

func (override BucketOverride) apply(base Bucket) Bucket {
	if override.Capacity != nil {
		base.Capacity = *override.Capacity
	}
	if override.RefillPerSecond != nil {
		base.RefillPerSecond = *override.RefillPerSecond
	}
	return base
}
