# ADR 0005: Every State Commit Is Fenced

- Status: Accepted
- Date: 2026-08-05

## Context

An expired lease alone permits a paused worker to resume after a replacement worker has changed state.

## Decision

Every activation acquisition monotonically increments `activation_generation`. State/message/outbox commit locks the instance and verifies:

- activation owner equals the committing worker
- activation generation equals the worker's token
- activation expiration is still in the future
- the message is owned by the same activation generation

If any predicate fails, the transaction raises `SolidObjects::LostActivation` and no state, completion, result, effect, reminder, or broadcast is persisted.

## Consequences

- Fencing tokens, not wall-clock expiry alone, prevent stale state writes.
- Generation overflow is practically unreachable with a signed 64-bit positive counter and is guarded by a check constraint.
- Any future storage backend must implement an equivalent conditional commit.
