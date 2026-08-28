# ADR 0006: At-Least-Once Mailbox Delivery

- Status: Accepted
- Date: 2026-08-05

## Context

A worker can die before committing a message, after actor code ran, or after external code performed an irreversible effect. Exactly-once execution cannot be guaranteed by a database mailbox.

## Decision

Mailbox delivery is at least once. State mutation, message completion, result persistence, and outbox insertion are atomic. An interrupted message whose commit is absent becomes eligible after lease recovery and may execute again.

Actor code receives message ID, request ID, attempt, enqueue time, and idempotency key. Documentation requires idempotency for effects outside the actor commit.

Message handlers themselves can run more than once. Sequential execution means that one valid activation runs one turn at a time. It does not guarantee that a handler runs only once. Handlers for transitions such as `launch`, `checkout`, or `submit` must inspect durable actor state and return safely when the transition already happened. External calls belong in an outbox and still require downstream idempotency.

## Consequences

- No exactly-once claim appears in the API or documentation.
- Pure state transitions are safe because failed transactions roll back.
- Application handlers need durable state guards for non-repeatable logical transitions.
- External systems require idempotency keys or deduplication.
- A synchronous invocation timing out does not cancel its durable message.
