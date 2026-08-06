# ADR 0004: Renewable Database Activation Leases

- Status: Accepted
- Date: 2026-08-05

## Context

One worker must process one actor at a time without holding a database connection for the actor's in-memory lifetime.

## Decision

The actor instance row stores an activation owner, expiration, and generation. PostgreSQL and MySQL workers select an available or expired actor with `FOR UPDATE SKIP LOCKED`. SQLite workers serialize the short claim transaction with `BEGIN IMMEDIATE`. Every strategy changes the owner, advances the generation, and sets a database-time expiration before commit.

Lease renewal is a conditional update matching instance, owner, and generation. Graceful release uses the same predicate. Actor execution never holds a database transaction or checked-out connection across application code.

## Consequences

- A paused process can lose an activation even if its process heartbeat remains current.
- Clock comparison uses the backend database's current time.
- Lease duration must exceed renewal interval and configuration validation enforces it.
- Expiration enables crash recovery but does not by itself reject stale writes; fencing does.
