# ADR 0012: Actor Messages Are Not Active Jobs

- Status: Accepted
- Date: 2026-08-05

## Context

Active Job and Solid Queue provide durable independent jobs, but the actor contract couples an ordered mailbox, one logical activation, mutable state, fencing, request results, and transactional outboxes.

## Decision

Solid Objects implements its own mailbox and runtime rather than representing each actor message as an ordinary Active Job.

Active Job may be used by host applications around Solid Objects, but it is not part of actor claiming, ordering, retries, state commit, effects, or reminders.

## Consequences

- Per-actor sequentiality is mandatory instead of opt-in concurrency control.
- Message retry and serialization semantics are owned by Solid Objects.
- State and message completion can be one database transaction.
- The gem has more runtime code than an Active Job wrapper, but its guarantees are explicit and enforceable.
