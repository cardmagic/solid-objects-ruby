# ADR 0003: Explicit Per-Actor Mailbox Sequences

- Status: Accepted
- Date: 2026-08-05

## Context

Timestamps do not provide a unique order under concurrency. Independent message claims can also let later messages overtake an earlier retry.

## Decision

Every actor instance owns `next_message_sequence`. Enqueue runs in one transaction that locks or atomically updates the instance, allocates the next number, inserts the durable message, and inserts its ready-membership row. The database enforces uniqueness of actor identity plus sequence.

Execution state is represented by table membership, not a status column:

- `solid_objects_messages` is durable message history and contains the envelope, attempts, timestamps, result, and latest error.
- `solid_objects_ready_messages` is the small hot set of messages eligible at `available_at`.
- `solid_objects_claimed_messages` is the small set currently assigned to an activation owner and fencing generation.
- `solid_objects_dead_letters` is the terminal failed set and diagnostic record.

The earliest nonterminal sequence is the only eligible message for an actor. Moving a message between ready, claimed, and dead-letter membership occurs in short transactions that lock the durable message. A retryable failure moves the message back to ready with a later availability time and blocks later messages. A dead letter no longer blocks the mailbox.

## Consequences

- Concurrent enqueue has a deterministic committed order.
- Sequence allocation is a per-actor serialization point.
- Hot actors cannot increase enqueue throughput by adding workers.
- Polling and claiming indexes stay proportional to live executable work, not completed history.
- Cross-table membership is an application invariant maintained under message and activation locks because SQL cannot express one unique constraint across several tables.
- Administrative retry of a dead letter creates a new mailbox message with a new sequence and links it to the dead letter.
