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

Claiming an actor writes a process UUID, a unique activation token,
database-time expiration, and a monotonically increasing generation. The token
separates concurrent activations in one process; the generation fences every
older activation. Every successful or failed message finalization locks the
instance and checks:

- owner UUID matches;
- activation token matches;
- generation matches;
- expiration is still in the future according to database time; and
- claimed-message membership names the same owner and generation.

A stale worker can continue running Ruby code, but it cannot commit state,
completion, or outboxes.

## Destruction

`reference.destroy` locks and deletes the actor instance in one transaction.
Cascading foreign keys delete its message history, ready and claimed
memberships, dead letters, reminders, effects, and broadcasts. The operation
returns `true` when it deletes an incarnation and `false` when no incarnation
exists.

The deleted instance primary key is also the fencing boundary. An activation
that was executing before destruction raises `LostActivation` when it attempts
to commit because its instance no longer exists. Reusing the logical actor
type and ID creates a fresh incarnation with a different primary key, default
state, and sequence 1; an old lease cannot address or commit into it.

An enqueue racing with destruction is ordered by the instance lock. Work that
commits first is deleted; work that observes the deletion retries against a new
incarnation. A claimed reminder cannot resurrect an old incarnation because
reminder delivery locks the source instance and atomically advances the
reminder with its mailbox insert.

Destruction removes pending and claimed outbox records, but it cannot recall
external I/O, actor-to-actor delivery, or a broadcast that began before the
delete. A stale outbox completion cannot record success, enqueue an actor
callback, or recreate the source actor. Applications must still make external
effect handlers idempotent.

Destruction is synchronous, forbidden from actor context, authorized by
`authorize_destroy`, and does not run `on_deactivate`.

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
def launch
  return if status == "launched"

  self.status = "launched"
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
  same-database commit actions, reminders, outbound actor messages, observable
  broadcasts, and the monotonic actor state revision;
- failed-attempt record plus ready reinsertion or dead letter;
- effect completion plus its optional actor outcome message;
- reminder occurrence enqueue plus reminder advancement; and
- actor destruction plus cascading removal of all actor-owned rows.

Actor Ruby code and external I/O are never inside the actor-state transaction.
Rails write prevention rejects direct Active Record writes while handlers,
observables, lifecycle hooks, or state migrations run. A registered commit
action is the only application-record write path inside the fenced commit, and
it is available only when Solid Objects and `ActiveRecord::Base` share one
connection pool. Commit actions must contain only bounded database work.
External I/O belongs in the effect outbox.

## Reactive components

A successful fenced turn advances `instances.state_revision` to that message's
per-actor sequence and inserts changed-observable broadcast rows in the same
transaction. A rollback, retryable handler failure, or lost activation advances
neither. Component HTML is not durable and is never placed on the shared actor
stream.

Each component token signs the actor identity, conventional component name,
explicit dependencies, initial instance ID and revision, and same-origin
refresh path. The signature detects modification but grants no access. Initial
rendering invokes query authorization, Cable separately invokes subscription
authorization, and the cookie-bearing refresh request invokes query
authorization again for the component name and every dependency.

The actor stream token separately signs the scalar observable targets rendered
into its scope. A component dependency that has no scalar target carries only
its name and revision over Cable, not its serialized value.

Cable compares `(instance_id, state_revision)` pairs, coalesces dependencies
changed by the same turn, and ignores an older pair after a newer one. A new
invalidation advances each keyed component registration independently. Replace
refreshes replace the whole Turbo Frame generation, so a response owned by the
detached older frame cannot overwrite the current frame. Morph refreshes abort
a superseded request for the same target and compare the response revision
with the current DOM revision immediately before applying Turbo's scoped
morph. Reconnect compares every component's signed initial pair with the
current instance row and requests the latest committed snapshot when stale.

Component keys, JSON locals, dependencies, and refresh strategy are covered by
the signed registration. Keys and locals are visible to the browser and are
passed back to `authorize_query` on every render; integrity never substitutes
for request-specific authorization.

## Synchronous invocation

A direct reference method or explicit `sync` call durably enqueues an ordinary
mailbox message. The caller then attempts to claim that actor and execute
through the same activation, lease renewal, fencing, and executor code used by
a worker. It drains earlier messages first and returns only the committed
result. A worker may win the activation instead; the caller then observes the
durable result through wake-up hints with bounded polling as fallback.

Timeout raises `SolidObjects::SyncTimeout` but does not cancel the message.
The exception reports actor identity, message ID and sequence, durable status,
an earlier mailbox blocker, and activation-owner metadata without exposing
arguments. Its `message_reference` can reauthorize and wait for the eventual
result. Adapter lock/query deadlines cover the durable enqueue, caller-process
registration and heartbeat, activation coordination, and result observation.
SQLite retries busy coordination operations only within the original call
deadline and reports `waiting_on=database_contention` when the database cannot
be inspected at timeout. If enqueue cannot commit, `SyncEnqueueTimeout` is
raised and no message reference exists. MySQL lock waits have one-second InnoDB
granularity. Ruby handlers that already started are not preempted.

A synchronous call made while the Solid Objects connection already has an open
transaction raises `SolidObjects::SyncInsideTransaction` before the message is
enqueued.
Destroying the actor while a synchronous caller waits removes its message,
wakes the caller, and raises `SolidObjects::ActorDestroyed`.

`async` performs only the durable enqueue and immediately returns a
`MessageReference`.

## Domain rejection

`reject` is a terminal domain outcome, not an infrastructure failure. It rolls
back in-memory state and staged intents, stores a structured rejection on the
message, removes claimed membership, and lets the next sequence run. It is
never retried or dead-lettered. The synchronous caller receives
`SolidObjects::Rejected`; asynchronous callers can inspect the message status.

## Database dependencies

PostgreSQL and MySQL use primary-key `FOR UPDATE SKIP LOCKED` attempts after a
read-only grouped scan of the narrow membership tables. SQLite relies on Active
Record's immediate write transactions and its one-writer serialization.

All three rely on transactional tables, foreign keys, unique constraints,
database time, and JSON-compatible columns. MySQL requires InnoDB.
