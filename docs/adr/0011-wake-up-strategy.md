# ADR 0011: Pluggable Wake-Up Strategy

- Status: Accepted
- Date: 2026-08-05

## Context

Polling adds latency and database queries. PostgreSQL notifications are transactional but transient, session-scoped, coalesced in some cases, and subject to listener startup races. MySQL has no equivalent notification primitive. Some applications already operate Redis and may choose it as a low-latency accelerator, but Redis is not required infrastructure and cannot become durable truth.

## Decision

Database rows remain the only durable source of work and results. Wake-up adapters only tell workers and `ask` waiters to re-query those rows.

The interface supports:

- Adaptive polling on every backend as the required fallback.
- An in-process condition signal for same-process workers and waiters.
- PostgreSQL `LISTEN/NOTIFY`.
- Optional Redis Pub/Sub for applications that already operate Redis.

MySQL uses polling or optional Redis. SQLite uses polling plus the in-process signal; multi-host SQLite is outside its supported operating model.

The coordination-overhead latency budget, measured from durable enqueue or completion commit until a waiting worker or caller begins its confirming query, is p99 at or below 100 milliseconds when a healthy cross-process wake-up adapter is enabled. Polling-only deployments accept up to the configured polling interval on each wait leg. End-to-end `ask` latency additionally includes queueing and actor execution and cannot have a library-wide bound.

Polling-only `ask` is intended for background callers, scripts, and control paths. It is not recommended in latency-sensitive Rails request handlers. A request handler may use it only with an explicit timeout and an operationally verified wake-up adapter and actor latency budget.

## Consequences

- Missing or duplicate notifications do not change correctness.
- PostgreSQL listeners need one dedicated connection while active.
- A reconnecting PostgreSQL listener must commit `LISTEN`, inspect current state, and then wait.
- Redis loss only increases latency and never loses durable work.
- Every adapter retains periodic polling to close startup, reconnect, and missed-message races.
- Notification payloads never contain actor arguments or results.
