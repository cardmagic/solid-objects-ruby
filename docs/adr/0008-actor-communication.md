# ADR 0008: Actor Communication Is Asynchronous

- Status: Accepted
- Date: 2026-08-05

## Context

If actor A synchronously waits for actor B while B waits for A, sequential actors deadlock. Waiting also extends activation occupation and database pressure.

## Decision

Actor references support durable asynchronous `tell`. `ask` is a caller-facing request/response operation and must not be called from actor code. Actor code uses staged actor messages or request/result message pairs.

Messages staged during actor execution are delivered through a transactional outbox so they exist if and only if the source message commits.

## Consequences

- Cyclic synchronous actor calls are rejected in actor context.
- Workflows spanning actors are explicit state machines or sagas.
- Cross-actor message order is not globally defined.
- Each target actor allocates its own mailbox sequence at delivery time.
