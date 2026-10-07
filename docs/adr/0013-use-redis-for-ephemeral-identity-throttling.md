# Use Redis for ephemeral identity throttling

DANS may meter each identity's request rate and DNS change throughput with Route 53-style token buckets shared by every API instance. Bucket state lives in one Redis-protocol server and is updated by a single Lua script that checks and consumes all applicable buckets atomically using Redis server time. Rate limiting is disabled by default, so deployments that do not enable it need no Redis.

Redis holds only disposable throttle state. Losing or flushing it resets buckets to full and changes no authorization, audit, zone-binding, or DNS state, so PostgreSQL remains the only durable state engine from ADR-0005 and Redis is excluded from backup, restore, and coordinated-upgrade procedures. Redis never gates readiness or authorization.

Throttling deliberately fails open, unlike authorization: when Redis is unreachable, errors, or exceeds a short timeout, DANS admits requests unmetered, logs bounded warnings and a recovery event, and resumes metering without restart. The per-instance concurrency cap remains the backstop during such outages. Requests whose cost can never fit a bucket's capacity are still rejected, because that check depends only on configuration.
