# ADR 0011: Pluggable Wake-Up Strategy

- Status: Accepted
- Date: 2026-08-05

## Context

Polling adds latency and database queries. PostgreSQL notifications are transactional but transient, session-scoped, coalesced in some cases, and subject to listener startup races. MySQL has no equivalent notification primitive. Some applications already operate Redis and may choose it as a low-latency accelerator, but Redis is not required infrastructure and cannot become durable truth.

## Decision

Database rows remain the only durable source of work and results. Wake-up
adapters only prompt workers and synchronous waiters to re-query those rows.

The interface supports:

- Adaptive polling on every backend as the required fallback.
- An in-process condition signal for same-process workers and waiters.
- PostgreSQL `LISTEN/NOTIFY`.
- Optional Redis Pub/Sub for applications that already operate Redis.

MySQL uses polling or optional Redis. SQLite uses polling plus the in-process signal; multi-host SQLite is outside its supported operating model.

The synchronous caller first attempts to claim and execute the actor locally,
so the normal path has no worker polling leg. When another process owns the
activation, coordination overhead from completion commit until the caller's
confirming query targets p99 at or below 100 milliseconds with a healthy
cross-process wake-up adapter. Polling fallback accepts up to
`sync_polling_interval` between observations. End-to-end latency still includes
earlier mailbox work and actor execution and cannot have a library-wide bound.

Direct methods and `sync` are intended for HTTP, MCP, scripts, and control
paths whose handler and mailbox latency fit an explicit application budget.
Timeout does not cancel durable work.

## Consequences

- Missing or duplicate notifications do not change correctness.
- PostgreSQL listeners need one dedicated connection while active.
- A reconnecting PostgreSQL listener must commit `LISTEN`, inspect current state, and then wait.
- Redis loss only increases latency and never loses durable work.
- Every adapter retains periodic polling to close startup, reconnect, and missed-message races.
- Notification payloads never contain actor arguments or results.
