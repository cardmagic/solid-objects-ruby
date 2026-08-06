# ADR 0013: MySQL, PostgreSQL, and SQLite Backends

- Status: Accepted
- Date: 2026-08-05
- Supersedes: ADR 0001

## Context

Solid Objects must work with the three databases Rails applications most commonly use without silently weakening mailbox ordering, activation ownership, or fencing.

The databases expose different coordination features:

- PostgreSQL and MySQL InnoDB support row locks and `FOR UPDATE SKIP LOCKED`.
- SQLite has no row-level `SKIP LOCKED`, permits one writer at a time, and supports `BEGIN IMMEDIATE`.
- PostgreSQL has JSONB, MySQL has JSON, and SQLite exposes Rails JSON serialization over its dynamic storage types.

## Decision

Solid Objects supports:

- PostgreSQL 14 or newer
- MySQL 8.0 or newer using InnoDB
- SQLite 3.35 or newer

A database adapter capability object owns:

- Non-blocking claim strategy
- Database current-time expression
- JSON column migration type

Explicit lock/deadlock/busy retry classification remains a hardening milestone.

PostgreSQL and MySQL use bounded `FOR UPDATE SKIP LOCKED` claims in short transactions.

SQLite uses the immediate write transactions provided by Rails 8 for coordination writes. Its single writer serializes candidate selection and claim. SQLite is correct for the tested contract but intended for development and modest single-host workloads because write concurrency is database-wide; explicit busy-error classification and retry are not yet implemented.

All backends use the same conditional fenced commit predicate. Adapter differences may change throughput and lock granularity, never delivery semantics.

Ready and claimed work live in narrow membership tables with ordinary composite indexes. Completed history never accumulates in the polling index, and no backend-specific partial index is required.

## Consequences

- The schema generator emits PostgreSQL JSONB, MySQL JSON, and SQLite JSON-compatible columns.
- PostgreSQL, MySQL, and SQLite use the same ready- and claimed-membership tables.
- MySQL tests require InnoDB and reject nontransactional table engines.
- SQLite uses the adapter's configured busy timeout; WAL mode is an application operating choice.
- Cross-backend integration tests exercise sequence allocation, claiming, lease renewal, fencing, atomic completion, and crash recovery.
- PostgreSQL remains the benchmark and high-concurrency reference backend.
