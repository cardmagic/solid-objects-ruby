# ADR 0007: External Effects and Broadcasts Use Outboxes

- Status: Accepted
- Date: 2026-08-05

## Context

Calling an external system or broadcasting before the actor transaction commits can create phantom effects. Calling it after commit without a durable record can lose effects.

## Decision

`emit` stages an effect. Successful message commit inserts the effect in the same database transaction as state and message completion. Observable changes likewise insert broadcast rows in that transaction. Separate workers claim and deliver outbox rows at least once.

Effect handlers must accept a stable effect ID as their idempotency key. Optional success and failure messages are enqueued back to the actor after delivery outcome is durably recorded.

## Consequences

- Slow network I/O never runs inside the actor-state transaction.
- Delivery may be duplicated after a worker crash.
- Consumers and effect handlers must be idempotent.
- Outbox retention and replay are operational concerns.
