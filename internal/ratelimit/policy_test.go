package ratelimit

import (
	"strings"
	"testing"
)

const testIdentity = "8f0a7d4e-3b2c-4d1e-9f6a-5b4c3d2e1f0a"

var testOperations = map[string]struct{}{
	"createZone": {}, "deleteZone": {}, "patchZone": {}, "listZones": {}, "searchData": {},
}

func TestBuiltinPolicyMirrorsRoute53Defaults(t *testing.T) {
	policy := BuiltinPolicy()
	checks := []struct {
		name string
		got  Bucket
		want Bucket
	}{
		{"identity requests", policy.Requests, Bucket{50, 10}},
		{"default operation", policy.OperationBucket("listZones"), Bucket{50, 10}},
		{"createZone", policy.OperationBucket("createZone"), Bucket{40, 2}},
		{"deleteZone", policy.OperationBucket("deleteZone"), Bucket{40, 5}},
		{"changes", policy.Changes, Bucket{1500, 100}},
	}
	for _, check := range checks {
		if check.got != check.want {
			t.Errorf("%s = %+v, want %+v", check.name, check.got, check.want)
		}
	}
	for kind, want := range map[string]int64{"REPLACE": 2, "DELETE": 1, "EXTEND": 1, "PRUNE": 1} {
		if got := policy.ChangeCosts[kind]; got != want {
			t.Errorf("change cost %s = %d, want %d", kind, got, want)
		}
	}
	if policy.MaxRequestChangeCost() != 200 {
		t.Fatalf("max request change cost = %d, want 200", policy.MaxRequestChangeCost())
	}
}

func TestPolicyPrecedenceIsPerField(t *testing.T) {
	table, warnings, err := ParsePolicy([]byte(`{
		"defaults": {
			"changes": {"capacity": 3000},
			"operations": {"*": {"refill_per_second": 20}, "createZone": {"capacity": 10}}
		},
		"identities": {
			"`+testIdentity+`": {
				"changes": {"refill_per_second": 200},
				"operations": {"createZone": {"refill_per_second": 1}},
				"change_costs": {"REPLACE": 3}
			}
		}
	}`), testOperations)
	if err != nil {
		t.Fatal(err)
	}
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", warnings)
	}

	identity := table.For(testIdentity)
	if identity.Changes != (Bucket{3000, 200}) {
		t.Errorf("identity changes = %+v, want capacity from defaults and refill from identity", identity.Changes)
	}
	if got := identity.OperationBucket("createZone"); got != (Bucket{10, 1}) {
		t.Errorf("identity createZone = %+v, want {10 1}", got)
	}
	if got := identity.ChangeCosts["REPLACE"]; got != 3 {
		t.Errorf("identity REPLACE cost = %d, want 3", got)
	}
	if got := identity.ChangeCosts["DELETE"]; got != 1 {
		t.Errorf("identity DELETE cost = %d, want built-in 1", got)
	}

	other := table.For("00000000-0000-4000-8000-000000000000")
	if other.Changes != (Bucket{3000, 100}) {
		t.Errorf("identity without entry changes = %+v, want defaults with built-in refill", other.Changes)
	}
	if got := other.OperationBucket("listZones"); got != (Bucket{50, 20}) {
		t.Errorf("default operation = %+v, want {50 20}", got)
	}
	if got := other.OperationBucket("deleteZone"); got != (Bucket{40, 5}) {
		t.Errorf("deleteZone = %+v, want built-in {40 5}", got)
	}
	if other.ChangeCosts["REPLACE"] != 2 {
		t.Errorf("identity overrides leaked into defaults")
	}
}

func TestNewBuiltinTableAppliesDefaultsToEveryone(t *testing.T) {
	if got := NewBuiltinTable().For(testIdentity).Requests; got != (Bucket{50, 10}) {
		t.Fatalf("requests = %+v", got)
	}
}

func TestParsePolicyRejectsInvalidDocuments(t *testing.T) {
	cases := map[string]string{
		"unknown property":          `{"default": {}}`,
		"unknown nested property":   `{"defaults": {"requests": {"burst": 5}}}`,
		"zero capacity":             `{"defaults": {"requests": {"capacity": 0}}}`,
		"fractional capacity":       `{"defaults": {"requests": {"capacity": 1.5}}}`,
		"negative refill":           `{"defaults": {"changes": {"refill_per_second": -1}}}`,
		"zero refill":               `{"defaults": {"changes": {"refill_per_second": 0}}}`,
		"empty bucket override":     `{"defaults": {"changes": {}}}`,
		"unknown operation":         `{"defaults": {"operations": {"createHostedZone": {"capacity": 5}}}}`,
		"unknown operation cost":    `{"defaults": {"operation_costs": {"createHostedZone": 2}}}`,
		"patch operation cost":      `{"defaults": {"operation_costs": {"patchZone": 2}}}`,
		"wildcard operation cost":   `{"defaults": {"operation_costs": {"*": 2}}}`,
		"unknown change kind":       `{"defaults": {"change_costs": {"UPSERT": 2}}}`,
		"negative cost":             `{"defaults": {"change_costs": {"DELETE": -1}}}`,
		"fractional cost":           `{"defaults": {"change_costs": {"DELETE": 0.5}}}`,
		"uppercase identity key":    `{"identities": {"8F0A7D4E-3B2C-4D1E-9F6A-5B4C3D2E1F0A": {}}}`,
		"handle identity key":       `{"identities": {"ci-bot": {}}}`,
		"invalid identity override": `{"identities": {"` + testIdentity + `": {"requests": {"capacity": -5}}}}`,
		"duplicate key":             `{"defaults": {}, "defaults": {}}`,
		"trailing value":            `{} {}`,
		"not an object":             `[]`,
		"wrong type":                `{"defaults": {"requests": {"capacity": "50"}}}`,
	}
	for name, document := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, err := ParsePolicy([]byte(document), testOperations); err == nil {
				t.Fatalf("ParsePolicy(%s) succeeded", document)
			}
		})
	}
}

func TestParsePolicyWarnsWhenARequestCanNeverFit(t *testing.T) {
	_, warnings, err := ParsePolicy([]byte(`{
		"defaults": {"changes": {"capacity": 200}},
		"identities": {"`+testIdentity+`": {"changes": {"capacity": 50}}}
	}`), testOperations)
	if err != nil {
		t.Fatal(err)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], testIdentity) || !strings.Contains(warnings[0], "200") {
		t.Fatalf("warnings = %v, want one warning naming the identity and largest cost", warnings)
	}
}
