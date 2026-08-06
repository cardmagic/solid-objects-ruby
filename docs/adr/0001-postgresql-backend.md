# ADR 0001: PostgreSQL Is the Initial Backend

- Status: Superseded by ADR 0013
- Date: 2026-08-05

## Context

The runtime needs durable mailboxes, atomic state/message/outbox commits, concurrent worker claiming, small execution-membership tables, safe row locks, and fencing predicates. Supporting the least-common SQL feature set would weaken or complicate those guarantees.

## Decision

Solid Objects originally planned to support PostgreSQL only. It would use the host application's PostgreSQL environment by default and could use a separate Rails database configuration. Every table participating in one actor commit would be in the same database.

This decision was superseded when the supported backend scope expanded to MySQL, PostgreSQL, and SQLite. PostgreSQL remains the optimized reference backend.

## Consequences

- Redis, Kafka, and a separate database server are not required.
- SQLite and MySQL require their own verified coordination implementations.
- PostgreSQL integration tests are part of correctness, not an optional adapter test.
- Cross-database transactions are unsupported.
