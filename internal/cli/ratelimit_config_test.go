package cli

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ncode/dans/internal/ratelimit"
)

const rateLimitTestIdentity = "8f0a7d4e-3b2c-4d1e-9f6a-5b4c3d2e1f0a"

func runServe(t *testing.T, server *fakeServer, args ...string) (int, string) {
	t.Helper()
	t.Setenv("DANS_DATABASE_URL", "postgres://dans@database/dans")
	t.Setenv("DANS_POWERDNS_API_KEY", "powerdns-secret")
	var stderr bytes.Buffer
	args = append([]string{"--powerdns-url", "http://127.0.0.1:8081"}, args...)
	code := Execute(context.Background(), append(args, "serve"), Options{
		Version: "test", Streams: Streams{Err: &stderr}, Server: server,
	})
	return code, stderr.String()
}

func TestRateLimitSettingsDefaultToDisabled(t *testing.T) {
	config, err := loadConfig(configTestCommand(t), configScopeOnline)
	if err != nil {
		t.Fatal(err)
	}
	limits, err := config.serveLimits()
	if err == nil && (limits.RateLimitEnabled || limits.RateLimitRedisTimeout != 25*time.Millisecond) {
		t.Fatalf("rate-limit defaults = enabled %v timeout %s", limits.RateLimitEnabled, limits.RateLimitRedisTimeout)
	}
	if config.RateLimitEnabled != "false" || config.RateLimitRedisTimeout != "25ms" {
		t.Fatalf("raw defaults = %q %q", config.RateLimitEnabled, config.RateLimitRedisTimeout)
	}
}

func TestRateLimitTimeoutUsesConfigurationPrecedence(t *testing.T) {
	path := writeConfigFile(t, t.TempDir(), "config.json", `{"rate_limit_redis_timeout":"50ms","rate_limit_enabled":"true"}`)
	t.Setenv("DANS_RATE_LIMIT_REDIS_TIMEOUT", "75ms")
	config, err := loadConfig(configTestCommand(t, "--config", path, "--rate-limit-redis-timeout", "100ms"), configScopeOnline)
	if err != nil {
		t.Fatal(err)
	}
	if config.RateLimitRedisTimeout != "100ms" || config.RateLimitEnabled != "true" {
		t.Fatalf("resolved = %q %q", config.RateLimitRedisTimeout, config.RateLimitEnabled)
	}
	config, err = loadConfig(configTestCommand(t, "--config", path), configScopeOnline)
	if err != nil {
		t.Fatal(err)
	}
	if config.RateLimitRedisTimeout != "75ms" {
		t.Fatalf("environment did not override the file: %q", config.RateLimitRedisTimeout)
	}
}

func TestServeRejectsInvalidRateLimitSettings(t *testing.T) {
	for name, args := range map[string][]string{
		"timeout too small":   {"--rate-limit-redis-timeout", "500us"},
		"timeout too large":   {"--rate-limit-redis-timeout", "2s"},
		"timeout malformed":   {"--rate-limit-redis-timeout", "soon"},
		"enabled not boolean": {"--rate-limit-enabled", "yes"},
	} {
		t.Run(name, func(t *testing.T) {
			server := &fakeServer{}
			if code, stderr := runServe(t, server, args...); code != 2 || server.calls != 0 {
				t.Fatalf("exit code = %d, calls = %d, stderr = %q", code, server.calls, stderr)
			}
		})
	}
}

func TestServeRequiresRedisURLOnlyWhenEnabled(t *testing.T) {
	server := &fakeServer{}
	code, stderr := runServe(t, server, "--rate-limit-enabled", "true")
	if code != 2 || server.calls != 0 || !strings.Contains(stderr, "DANS_REDIS_URL") {
		t.Fatalf("enabled without URL: code %d, calls %d, stderr %q", code, server.calls, stderr)
	}

	missing := t.TempDir() + "/missing"
	server = &fakeServer{}
	code, stderr = runServe(t, server, "--redis-url-file", missing, "--rate-limit-policy-file", missing)
	if code != 0 || server.calls != 1 {
		t.Fatalf("disabled with backend settings: code %d, stderr %q", code, stderr)
	}
	if server.config.RateLimitEnabled || server.config.RedisURL.Value() != "" || server.config.RateLimitPolicy != nil {
		t.Fatalf("disabled mode resolved rate-limit dependencies: %#v", server.config)
	}
}

func TestServeResolvesRedisURLAndBuiltinPolicy(t *testing.T) {
	t.Setenv("DANS_REDIS_URL", "redis://:redis-secret@redis:6379/0")
	server := &fakeServer{}
	code, stderr := runServe(t, server, "--rate-limit-enabled", "true", "--rate-limit-redis-timeout", "40ms")
	if code != 0 {
		t.Fatalf("exit code = %d, stderr = %q", code, stderr)
	}
	config := server.config
	if !config.RateLimitEnabled || config.RateLimitRedisTimeout != 40*time.Millisecond || config.RedisURL.Value() != "redis://:redis-secret@redis:6379/0" {
		t.Fatalf("serve config = %#v", config)
	}
	if config.RateLimitPolicy == nil || config.RateLimitPolicy.For(rateLimitTestIdentity).Requests != (ratelimit.Bucket{Capacity: 50, RefillPerSecond: 10}) {
		t.Fatal("serve did not receive the built-in policy")
	}
	if strings.Contains(fmt.Sprintf("%v %#v", config, config), "redis-secret") {
		t.Fatal("serve config formatting exposed the Redis URL")
	}
}

func TestServeReadsRedisURLFileAndPolicyFile(t *testing.T) {
	dir := t.TempDir()
	urlFile := writeConfigFile(t, dir, "redis-url", "rediss://:redis-secret@redis.internal:6380/0\n")
	policyFile := writeConfigFile(t, dir, "policy.json", `{
		"defaults": {"changes": {"capacity": 3000}},
		"identities": {"`+rateLimitTestIdentity+`": {"changes": {"capacity": 50}}}
	}`)
	server := &fakeServer{}
	code, stderr := runServe(t, server, "--rate-limit-enabled", "true", "--redis-url-file", urlFile, "--rate-limit-policy-file", policyFile)
	if code != 0 {
		t.Fatalf("exit code = %d, stderr = %q", code, stderr)
	}
	if server.config.RedisURL.Value() != "rediss://:redis-secret@redis.internal:6380/0" {
		t.Fatal("Redis URL file was not normalized")
	}
	if got := server.config.RateLimitPolicy.For(rateLimitTestIdentity).Changes.Capacity; got != 50 {
		t.Fatalf("identity change capacity = %d", got)
	}
	if got := server.config.RateLimitPolicy.For("00000000-0000-4000-8000-000000000000").Changes.Capacity; got != 3000 {
		t.Fatalf("default change capacity = %d", got)
	}
	if len(server.config.RateLimitWarnings) != 1 || !strings.Contains(server.config.RateLimitWarnings[0], rateLimitTestIdentity) {
		t.Fatalf("warnings = %v", server.config.RateLimitWarnings)
	}
}

func TestServeRejectsInvalidRateLimitSecretsAndPolicies(t *testing.T) {
	dir := t.TempDir()
	cases := map[string]struct {
		env  map[string]string
		args []string
	}{
		"malformed URL": {env: map[string]string{"DANS_REDIS_URL": "postgres://user:redis-secret@db/dans"}},
		"invalid database": {
			env: map[string]string{"DANS_REDIS_URL": "redis://user:redis-secret@redis.internal/not-a-db"},
		},
		"out-of-range port": {
			env: map[string]string{"DANS_REDIS_URL": "redis://user:redis-secret@redis.internal:65536/0"},
		},
		"invalid database in file": {
			args: []string{"--redis-url-file", writeConfigFile(t, dir, "bad-database-url", "rediss://user:redis-secret@redis.internal/not-a-db\n")},
		},
		"out-of-range port in file": {
			args: []string{"--redis-url-file", writeConfigFile(t, dir, "bad-port-url", "rediss://user:redis-secret@redis.internal:65536/0\n")},
		},
		"competing URL sources": {
			env:  map[string]string{"DANS_REDIS_URL": "redis://redis:6379"},
			args: []string{"--redis-url-file", writeConfigFile(t, dir, "url", "redis://:redis-secret@redis:6379")},
		},
		"invalid policy": {
			env:  map[string]string{"DANS_REDIS_URL": "redis://:redis-secret@redis:6379"},
			args: []string{"--rate-limit-policy-file", writeConfigFile(t, dir, "bad.json", `{"defaults":{"requests":{"capacity":0}}}`)},
		},
		"null costs": {
			env:  map[string]string{"DANS_REDIS_URL": "redis://:redis-secret@redis:6379"},
			args: []string{"--rate-limit-policy-file", writeConfigFile(t, dir, "null-costs.json", `{"defaults":{"change_costs":{"REPLACE":null},"operation_costs":{"createZone":null}}}`)},
		},
		"unrepresentable bucket duration": {
			env:  map[string]string{"DANS_REDIS_URL": "redis://:redis-secret@redis:6379"},
			args: []string{"--rate-limit-policy-file", writeConfigFile(t, dir, "slow-refill.json", `{"defaults":{"requests":{"capacity":1,"refill_per_second":1e-20}}}`)},
		},
		"unknown operation": {
			env:  map[string]string{"DANS_REDIS_URL": "redis://:redis-secret@redis:6379"},
			args: []string{"--rate-limit-policy-file", writeConfigFile(t, dir, "op.json", `{"defaults":{"operations":{"createHostedZone":{"capacity":1}}}}`)},
		},
		"missing policy": {
			env:  map[string]string{"DANS_REDIS_URL": "redis://:redis-secret@redis:6379"},
			args: []string{"--rate-limit-policy-file", dir + "/absent.json"},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			for key, value := range tc.env {
				t.Setenv(key, value)
			}
			server := &fakeServer{}
			code, stderr := runServe(t, server, append([]string{"--rate-limit-enabled", "true"}, tc.args...)...)
			if code != 2 || server.calls != 0 {
				t.Fatalf("exit code = %d, calls = %d, stderr = %q", code, server.calls, stderr)
			}
			if strings.Contains(stderr, "redis-secret") || strings.Contains(stderr, "redis.internal") || strings.Contains(stderr, "not-a-db") {
				t.Fatalf("diagnostic exposed the Redis secret: %q", stderr)
			}
		})
	}
}

func TestLiteralRedisURLFlagAndJSONAreRejected(t *testing.T) {
	const literal = "redis://:must-not-be-printed@redis:6379"
	server := &fakeServer{}
	code, stderr := runServe(t, server, "--redis-url="+literal)
	if code != 2 || server.calls != 0 || strings.Contains(stderr, "must-not-be-printed") {
		t.Fatalf("literal flag: code %d, stderr %q", code, stderr)
	}
	path := writeConfigFile(t, t.TempDir(), "literal.json", `{"redis_url":"`+literal+`"}`)
	if _, err := loadConfig(configTestCommand(t, "--config", path), configScopeServe); err == nil || strings.Contains(err.Error(), "must-not-be-printed") {
		t.Fatalf("literal JSON value error = %v", err)
	}
}

func TestServeFailureRedactsRedisCredentials(t *testing.T) {
	t.Setenv("DANS_REDIS_URL", "redis://default:redis-password@redis:6379/0")
	code, stderr := runServe(t, &fakeServer{err: fmt.Errorf("dial redis://default:redis-password@redis:6379/0 failed")}, "--rate-limit-enabled", "true")
	if code != 1 {
		t.Fatalf("exit code = %d", code)
	}
	if strings.Contains(stderr, "redis-password") {
		t.Fatalf("runtime failure exposed the Redis password: %q", stderr)
	}
}

func TestDocumentedRateLimitPolicyIsValid(t *testing.T) {
	docs, err := os.ReadFile(filepath.Join("..", "..", "docs", "cli.md"))
	if err != nil {
		t.Fatal(err)
	}
	_, section, found := strings.Cut(string(docs), "### Rate-limit policy file")
	if !found {
		t.Fatal("docs/cli.md lacks the policy file section")
	}
	_, block, found := strings.Cut(section, "```json\n")
	if !found {
		t.Fatal("policy section lacks a JSON example")
	}
	example, _, _ := strings.Cut(block, "```")
	path := writeConfigFile(t, t.TempDir(), "policy.json", example)
	table, warnings, err := loadRateLimitPolicy(path)
	if err != nil {
		t.Fatalf("documented policy is invalid: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("documented policy warns: %v", warnings)
	}
	if got := table.For("8f0a7d4e-3b2c-4d1e-9f6a-5b4c3d2e1f0a").Changes; got != (ratelimit.Bucket{Capacity: 3000, RefillPerSecond: 500}) {
		t.Fatalf("documented identity change bucket = %+v", got)
	}
}
