# Correctness and delivery semantics

## Contract

Messages for one actor are durably enqueued and processed sequentially, at
least once, by at most one valid activation lease holder at a time. Different
actor identities may execute concurrently.

Exactly-once execution is not provided.

## Ordering

Enqueue locks the actor instance, allocates `next_message_sequence`, and inserts
the durable message and ready membership in one transaction. Unique indexes on
instance/sequence and actor identity/sequence enforce the final invariant.

The activation always claims the lowest live sequence for its actor. A
retryable failure returns that message to ready membership, so it blocks later
messages until success or dead-lettering.

## Ownership and fencing

Claiming an actor writes a process UUID, database-time expiration, and a
monotonically increasing generation. Every successful or failed message
finalization locks the instance and checks:

- owner UUID matches;
- generation matches;
- expiration is still in the future according to database time; and
- claimed-message membership names the same owner and generation.

A stale worker can continue running Ruby code, but it cannot commit state,
completion, or outboxes.

## Crash matrix

| Failure point | Durable outcome |
| --- | --- |
| Before message claim | Ready membership remains. |
| After claim, before handler | Claimed membership is recovered after lease loss. |
| During handler | In-memory work is lost and the message can run again. |
| During fenced commit | The database commits every state/message/outbox write or none. |
| After fenced commit | The message is complete; there is no separate acknowledgement to lose. |
| During external effect | The stable effect ID is reused, but the provider call can repeat. |
| During broadcast delivery | The durable row retries; reconnect refresh repairs client staleness. |

## Handler idempotency

Sequential does not mean once. A message such as `launch` still needs a durable
guard:

```ruby
message :launch do
  return if state.status == "launched"

  state.status = "launched"
  emit :launch_vehicle, launch_id: actor_id
end
```

The guard prevents a repeated state transition. The effect consumer still
deduplicates with `context.id`.

## Atomic boundaries

The following are atomic:

- actor creation, sequence allocation, durable message, and ready membership;
- activation owner, expiration, and generation acquisition;
- ready-to-claimed membership move and attempt increment;
- state, state version, message result/completion, claimed deletion, effects,
  reminders, outbound actor messages, and observable broadcasts;
- failed-attempt record plus ready reinsertion or dead letter;
- effect completion plus its optional actor outcome message.

Actor Ruby code and external I/O are never inside the actor-state transaction.

## Ask

`ask` is a durable message followed by result polling and wake-up hints. Timeout
does not cancel the message. The current cross-process fallback is polling;
therefore polling-only ask is not recommended in latency-sensitive HTTP paths.

## Database dependencies

PostgreSQL and MySQL use primary-key `FOR UPDATE SKIP LOCKED` attempts after a
read-only grouped scan of the narrow membership tables. SQLite relies on Active
Record's immediate write transactions and its one-writer serialization.

All three rely on transactional tables, foreign keys, unique constraints,
database time, and JSON-compatible columns. MySQL requires InnoDB.
