package ratelimit

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gomodule/redigo/redis"
)

func decodeEvents(t *testing.T, logs *bytes.Buffer) []map[string]any {
	t.Helper()
	var events []map[string]any
	for line := range strings.SplitSeq(strings.TrimSpace(logs.String()), "\n") {
		if line == "" {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("decode %q: %v", line, err)
		}
		events = append(events, event)
	}
	return events
}

func TestReporterBoundsWarningsAndReportsRecovery(t *testing.T) {
	clock := newFakeClock()
	logs := new(bytes.Buffer)
	reporter := NewReporter(slog.New(slog.NewJSONHandler(logs, nil)), 10*time.Second, clock.Now)
	cause := errors.New("dial tcp redis.internal:6379: connect: connection refused redis://:secret@redis")

	reporter.Success() // healthy successes log nothing
	for range 100 {
		reporter.Failure(cause)
		clock.Advance(50 * time.Millisecond)
	}
	clock.Advance(10 * time.Second)
	reporter.Failure(cause)
	reporter.Success()
	reporter.Success()

	events := decodeEvents(t, logs)
	if len(events) != 3 {
		t.Fatalf("events = %v, want first warning, one interval warning, one recovery", events)
	}
	if events[0]["event"] != EventFailOpen || events[0]["level"] != "WARN" || events[0]["suppressed"] != float64(0) {
		t.Fatalf("first event = %v", events[0])
	}
	if events[1]["event"] != EventFailOpen || events[1]["suppressed"] != float64(99) {
		t.Fatalf("interval event = %v, want 99 suppressed", events[1])
	}
	if events[2]["event"] != EventRecovered || events[2]["unmetered_admissions"] != float64(101) {
		t.Fatalf("recovery event = %v", events[2])
	}
	for _, forbidden := range []string{"redis.internal", "secret", "connection refused"} {
		if strings.Contains(logs.String(), forbidden) {
			t.Fatalf("logs contain %q: %s", forbidden, logs)
		}
	}
}

func TestReporterStartsANewEpisodeAfterRecovery(t *testing.T) {
	logs := new(bytes.Buffer)
	reporter := NewReporter(slog.New(slog.NewJSONHandler(logs, nil)), time.Hour, nil)
	reporter.Failure(errors.New("down"))
	reporter.Success()
	reporter.Failure(errors.New("down again"))
	if events := decodeEvents(t, logs); len(events) != 3 || events[2]["event"] != EventFailOpen {
		t.Fatalf("events = %v, want a fresh warning for the second outage", events)
	}
}

type timeoutError struct{}

func (timeoutError) Error() string   { return "i/o timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }

func TestClassify(t *testing.T) {
	cases := map[string]struct {
		err  error
		want string
	}{
		"deadline":      {context.DeadlineExceeded, ReasonTimeout},
		"net timeout":   {&net.OpError{Op: "read", Err: timeoutError{}}, ReasonTimeout},
		"refused":       {&net.OpError{Op: "dial", Err: errors.New("connection refused")}, ReasonConnection},
		"closed pool":   {errors.New("redigo: get on closed pool"), ReasonConnection},
		"script reply":  {redis.Error("ERR user_script:1: boom"), ReasonScript},
		"unknown error": {errors.New("anything"), ReasonConnection},
	}
	for name, tc := range cases {
		if got := Classify(tc.err); got != tc.want {
			t.Errorf("%s: Classify = %q, want %q", name, got, tc.want)
		}
	}
}

func TestRunbookNamesTheLoggedEvents(t *testing.T) {
	runbook, err := os.ReadFile(filepath.Join("..", "..", "docs", "operations", "runbooks.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{EventFailOpen, EventRecovered, "suppressed", "unmetered_admissions", ReasonTimeout, ReasonConnection, ReasonScript} {
		if !strings.Contains(string(runbook), "`"+name+"`") {
			t.Errorf("docs/operations/runbooks.md does not name %q", name)
		}
	}
}
