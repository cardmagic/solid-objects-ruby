# ADR 0002: Actor State Uses Native JSON Storage

- Status: Accepted
- Date: 2026-08-05

## Context

Actor state must be durable, inspectable, safely serialized, and evolvable without creating a table per actor type.

## Decision

Each actor instance stores one native JSON state document and an integer state version. PostgreSQL uses JSONB; MySQL uses JSON; SQLite uses the Rails JSON type over SQLite storage. State and all message-related values are limited to JSON-compatible primitives, arrays, and objects with string keys. Serialization is validated before persistence.

Actors declare attributes, defaults, a current state version, and explicit one-step migrations. Migrations run in memory before a message executes and persist only with a successful fenced message commit.

## Consequences

- No `Marshal` or arbitrary object deserialization is allowed.
- Large or query-heavy domain data should remain in normalized application tables, not actor state.
- State migrations are application code and must remain compatible during rolling deployments.
- Serializer extension points must still produce trusted JSON-compatible representations.
