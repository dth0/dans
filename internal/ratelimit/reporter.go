package ratelimit

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gomodule/redigo/redis"
)

// Log event names are a documented operational contract.
const (
	EventFailOpen  = "rate_limit.fail_open"
	EventRecovered = "rate_limit.recovered"

	// DefaultWarningInterval bounds fail-open warnings during an outage.
	DefaultWarningInterval = 10 * time.Second
)

// Failure reason classes. They never contain backend addresses or credentials.
const (
	ReasonTimeout    = "timeout"
	ReasonConnection = "connection"
	ReasonScript     = "script"
)

// Reporter turns backend failures into bounded warnings and one recovery event.
type Reporter struct {
	logger   *slog.Logger
	now      func() time.Time
	interval time.Duration

	degraded atomic.Bool

	mu         sync.Mutex
	lastWarn   time.Time
	suppressed int64
	unmetered  int64
}

// NewReporter creates a reporter. A nil clock uses time.Now.
func NewReporter(logger *slog.Logger, interval time.Duration, now func() time.Time) *Reporter {
	if logger == nil {
		logger = slog.New(slog.DiscardHandler)
	}
	if interval <= 0 {
		interval = DefaultWarningInterval
	}
	if now == nil {
		now = time.Now
	}
	return &Reporter{logger: logger, now: now, interval: interval}
}

// Failure records one fail-open admission caused by err.
func (reporter *Reporter) Failure(err error) {
	reason := Classify(err)
	reporter.mu.Lock()
	defer reporter.mu.Unlock()
	now := reporter.now()
	reporter.unmetered++
	if !reporter.degraded.Load() {
		reporter.degraded.Store(true)
		reporter.lastWarn = now
		reporter.suppressed = 0
		reporter.logger.Warn(EventFailOpen, "event", EventFailOpen, "reason", reason, "suppressed", int64(0))
		return
	}
	if now.Sub(reporter.lastWarn) < reporter.interval {
		reporter.suppressed++
		return
	}
	reporter.logger.Warn(EventFailOpen, "event", EventFailOpen, "reason", reason, "suppressed", reporter.suppressed)
	reporter.lastWarn = now
	reporter.suppressed = 0
}

// Success records a metered request and emits a recovery event after an outage.
func (reporter *Reporter) Success() {
	if !reporter.degraded.Load() {
		return
	}
	reporter.mu.Lock()
	defer reporter.mu.Unlock()
	if !reporter.degraded.Load() {
		return
	}
	reporter.logger.Info(EventRecovered, "event", EventRecovered, "unmetered_admissions", reporter.unmetered)
	reporter.degraded.Store(false)
	reporter.unmetered = 0
	reporter.suppressed = 0
}

// Classify maps a backend error to a reason class without exposing its text.
func Classify(err error) string {
	var netErr net.Error
	switch {
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &netErr) && netErr.Timeout():
		return ReasonTimeout
	case isRedisReply(err):
		return ReasonScript
	default:
		return ReasonConnection
	}
}

func isRedisReply(err error) bool {
	var reply redis.Error
	return errors.As(err, &reply)
}
