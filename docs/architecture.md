# Solid Objects Architecture

## Purpose

Solid Objects ports the Cloudflare Durable Objects programming model to Rails.
It is a database-backed virtual actor runtime for MySQL, PostgreSQL, and
SQLite. A virtual actor is a logical object addressed by type and ID whose
in-memory activation is created on demand, processes one mailbox turn at a
time, persists JSON state, and can disappear when idle without losing its
identity or state. This ports the programming model, not Cloudflare's
serverless runtime, global placement, storage API, or platform guarantees.

The runtime contract is:

> Messages for one actor are durably enqueued and processed sequentially, at least once, by at most one valid activation lease holder at a time.

This is not an exactly-once system. Different actor identities can execute concurrently.

## Boundaries

Solid Objects owns:

- Actor type registration and logical references
- Durable mailbox ordering
- Actor state serialization and version migration
- Activation leasing and fencing
- Message retries and dead letters
- Effects, reminders, and broadcast outboxes
- Worker process registration and supervision
- Rails instrumentation and optional realtime integration

The host application owns:

- Authentication and authorization policy
- Actor class definitions
- Effect handler implementation and idempotency
- Deployment compatibility of actor code and state
- Database capacity, backups, and monitoring
- Action Cable production adapter and topology

## Database coordination adapters

Solid Objects supports PostgreSQL 14+, MySQL 8.0+ with InnoDB, and SQLite 3.35+.

One adapter capability object is selected from the Active Record connection. It supplies claim locking and database-time expressions. Unsupported adapter families fail when first used. Minimum server-version and storage-engine checks are documented operating requirements; automatic boot-time enforcement and classified contention retries remain hardening work.

PostgreSQL is the high-concurrency reference backend. MySQL uses the same row-lock claiming shape but requires careful indexed scans to avoid excessive next-key locks. SQLite is correct for the same public contract but is operationally suited to development and modest single-host workloads because every write transaction serializes at the database-file level.

Adapter-specific implementation is not permitted to weaken fencing. A stale owner must fail the same conditional commit on every backend.

## Components

### Actor registry

The registry maps a stable persisted actor type string to a Ruby actor class. Registration rejects duplicate names and invalid classes. Runtime dispatch never constantizes a database value.

### Actor reference

A reference contains actor type and normalized actor ID. It is cheap,
serializable as data, and does not imply an active Ruby object. Declared
message, query, and attribute methods use synchronous caller-assisted
invocation. `sync` provides the same behavior for a dynamic operation name,
while `async` only durably enqueues a message and returns its reference.
`destroy` is a reserved synchronous reference operation. Every path authorizes
through the client.

### Client and mailbox

The client finds or creates the actor instance and atomically allocates a sequence. It inserts one durable message-history row and one ready-membership row. It validates message names and JSON payloads before writing and enforces idempotency-key uniqueness, payload limits, and the per-actor mailbox cap. It also authorizes and coordinates actor destruction. Distributed rate limiting and global admission control are not implemented.

Message execution state is table membership, not a status column. The durable message remains for results, retention, and diagnostics. Only live work occupies `ready_messages` or `claimed_messages`, so completed history cannot inflate the polling index.

### Activation lease

An activation lease is stored on the actor instance:

- Owner process UUID
- Unique activation token
- Database-time expiration
- Monotonic generation

Acquisition and renewal are short database writes. A fresh activation token
distinguishes concurrent activations owned by the same process. Generation is
the monotonic fencing token used by every state commit.

### Activation

An activation is an in-memory actor object, its state, its current lease, and last-used time. It processes the earliest nonterminal sequence represented in the ready or claimed membership tables. It can drain a bounded number of messages before yielding.

### Worker

A worker:

1. Registers and starts heartbeating.
2. Selects candidate actors with due work.
3. Claims an activation through the configured database coordination adapter.
4. Loads and migrates state.
5. Runs one message turn outside a database transaction.
6. Commits state, completion, result, and outboxes in a short fenced transaction.
7. Renews the lease when necessary.
8. Yields after configured message or duration limits.
9. Keeps or releases the activation according to idle policy.
10. Stops claiming during graceful shutdown and releases owned leases after turns finish.

### Supervisor

The supervisor starts configured worker, effect, reminder, and broadcast thread roles and coordinates graceful shutdown. It does not yet replace a failed role or periodically prune stale process records; operators run the cleanup command separately. Database leases and fencing, rather than thread supervision, provide correctness.

### Effect worker

An effect worker claims due effect rows through the database coordination adapter, invokes a registered handler outside a database transaction, then records success or retryable failure. The handler receives the effect UUID as its idempotency key. Optional outcome messages are normal actor mailbox messages.

### Reminder scheduler

The scheduler claims due reminder definitions, locks the source actor instance,
then enqueues the ordinary actor message and advances or completes the reminder
in one transaction. A unique occurrence key prevents two schedulers from
producing two mailbox rows for the same reminder occurrence. Locking the source
instance first prevents a claimed reminder from recreating a destroyed actor.

### Broadcast worker

The broadcast worker claims committed observable-change rows, renders idempotent Turbo replacements, broadcasts to a signed actor stream, and records delivery. Current actor state remains the reconnect source of truth.

### Process registry

Every runtime role has a UUID process row containing kind, hostname, PID, start and heartbeat times, metadata, and shutdown state. Heartbeats run independently from work loops.

## Actor definition model

```ruby
class OrderActor < SolidObjects::Actor
  actor_type "orders"

  attribute :status, default: "draft"

  def submit
    self.status = "submitted"
  end

  observable :status
end
```

`attribute` creates actor instance readers and writers and an ordered read query.
Public instance methods declared on the actor are messages. Declare helpers as
private or protected. Messages and queries are exposed as methods on a
reference through the same synchronous caller-assisted path. Returned state
snapshots are deeply frozen. Use `async` for durable fire-and-forget delivery
and `sync` for dynamic operation names. The explicit `message` DSL remains
available for dynamic definitions.

`message` and `query` both execute as durable mailbox turns. A query may not
mutate state. The executor detects query mutation and fails the message. An
observable is a named projection of state used by server rendering and realtime
updates; it is not independently persisted.

Lifecycle hooks are deterministic local hooks:

- `on_activate` runs after state load and migration. State changes made there are included with the next successful message commit, not persisted on activation alone.
- `on_deactivate` runs only on graceful local deactivation. Its state changes are not persisted and it must not be used for durable work. Explicit destruction does not run lifecycle hooks.

Durable application cleanup belongs in messages, reminders, or effects.

## Enqueue and sequence allocation

Enqueue uses one transaction:

1. Resolve actor class from the registry.
2. Validate authorization, message name, actor ID, arguments, and size.
3. `INSERT ... ON CONFLICT` the actor instance if missing.
4. Lock the instance row.
5. Enforce the mailbox limit.
6. Read and increment `next_message_sequence`.
7. Insert the durable message with that sequence.
8. Insert its ready-membership row.
9. Commit.
10. Emit instrumentation and a non-durable wake-up hint.

The increment and insert roll back together. The unique index on `(actor_type, actor_id, sequence)` is the final invariant. Concurrent first access is resolved by the unique actor identity index and retrying the instance lookup.

Committed concurrent enqueues have one database-defined sequence order. No order is promised between transactions that have not committed.

## Actor destruction

`ActorClass.ref(actor_id).destroy` is a synchronous, idempotent runtime
operation. It is forbidden from actor context and has a separate
`authorize_destroy` policy that runs before actor existence is revealed.

Destruction uses one transaction:

1. Resolve the actor type through the registry.
2. Authorize the actor type and ID.
3. Lock the actor instance by logical identity.
4. Return `false` if it does not exist.
5. Delete the instance.
6. Let foreign-key cascades delete message history, ready and claimed
   memberships, dead letters, reminders, effects, and broadcasts.
7. Commit, emit `solid_objects.actor.destroyed`, and wake local waiters.

The instance primary key is the actor-incarnation boundary. A worker holding an
old lease can continue running Ruby code, but its fenced transaction cannot
find the deleted instance and raises `LostActivation`. If the same logical
identity is referenced later, enqueue creates a new instance with default
state, state version, sequence 1, and a new primary key. An enqueue that loses
the instance between lookup and locking retries against the new incarnation.

A claimed reminder locks the source instance before enqueueing its occurrence,
so it either commits before destruction and is deleted by the cascade, or
observes the missing instance and does nothing. An already-running external
effect, actor-to-actor delivery, or broadcast may have crossed the database
boundary before destruction; it cannot be recalled. Its completion sees the
deleted outbox row and cannot enqueue a callback or recreate the source actor.

## Candidate selection and fairness

An actor is eligible when:

- Its activation is unowned or expired.
- Its earliest ready message is due and no earlier claimed message exists.
- It is not administratively paused.

Candidate discovery is a read-only grouped scan of the narrow ready and claimed membership tables, ordered by each actor's earliest due or stale claimed work. For each candidate, PostgreSQL and MySQL attempt a primary-key instance-row lock with `FOR UPDATE SKIP LOCKED`, then recheck lease eligibility under that lock. This avoids MySQL next-key locking across a broad joined scan. SQLite performs the same short claim through Active Record's immediate write transaction and serializes writers at the database level.

When an activation exhausts its pass budget, the worker releases its lease and sets its already-due ready memberships to the current database time. Their durable message availability is unchanged. Actors that have been waiting longer therefore precede the yielded hot actor on the next grouped scan.

Within one activation pass, the worker stops after either:

- `max_messages_per_activation_pass`
- `max_activation_duration`
- No due earliest message
- Lease loss
- Shutdown request

The actor can be cached until `idle_deactivation_timeout`, and the worker continues renewing its lease while it is cached. The initial cache has no separate capacity limit; bounded cache eviction is a hardening milestone. Idle release runs the nondurable deactivation hook and conditionally releases the lease.

## Message execution

Before actor code:

1. Renew if the lease would expire before the next renewal window.
2. Load the earliest nonterminal mailbox sequence.
3. Atomically move its ready membership to claimed membership for the current owner, activation token, and generation and increment the durable attempt counter.
4. Set the actor's current message context.
5. Snapshot state and observable values.

Actor code then executes with no open database transaction and no pinned connection. It can:

- Read and mutate its in-memory state for a message
- Read state for a query
- Stage effects
- Stage reminders
- Stage asynchronous actor messages

It cannot:

- Call another actor directly or with `sync` from actor context
- Perform a synchronous actor-to-actor wait
- Assume execution happens once
- Commit actor state directly

After actor code, the executor validates state and staged data as JSON and computes changed observables.

## Fenced commit

Successful completion uses one database transaction:

1. Lock the instance row.
2. Verify owner, activation token, generation, and an unexpired lease using database time.
3. Lock the durable message and verify its claimed membership belongs to that owner, activation token, and generation.
4. Update native JSON state and state version.
5. Store the completion timestamp and result on the durable message and delete claimed membership.
6. Insert staged effects.
7. Insert or update staged reminders.
8. Insert staged actor-message outbox rows.
9. Insert changed-observable broadcast rows.
10. Update actor last-used time.
11. Commit.

Any lease or message predicate failure raises `LostActivation` and rolls back every item. The stale worker discards its in-memory activation.

The state version can advance because of state migration even when the message itself makes no state change.

## Failure path

Actor exceptions roll back all in-memory changes by restoring the pre-turn state. A separate short transaction conditionally owned by the current generation:

- Stores a sanitized error
- Deletes claimed membership
- Reinserts ready membership with retry availability using backoff
- Or creates a dead letter without reinserting ready membership

If the lease was lost, even failure finalization is abandoned. The new activation recovers the stale claimed membership.

The default ordering policy is strict:

- A retryable failed message blocks later messages.
- After it exceeds the retry limit and becomes dead, the next sequence may run.
- Operators can inspect and retry a dead letter.
- Retrying creates a new message at the tail; it does not rewrite history or jump ahead.

## Crash scenarios

### Worker dies before starting actor code

The activation lease eventually expires. A new worker advances the generation, recovers the earliest stale claimed membership, and executes it.

### Worker dies during actor code

No actor transaction was open. Its computed state is lost. After lease expiry, another worker executes the message again with the previously committed state.

### Worker dies during commit before the database commits

The database rolls back the transaction. The message executes again after lease recovery.

### Worker dies after commit but before local acknowledgement

The completed message and new state are already durable. The replacement activation skips the completed sequence. The original actor code is not rerun for that message.

### Worker pauses, lease expires, and another worker commits

The replacement has a higher generation. When the paused worker resumes, its conditional commit fails and all of its state and outbox changes roll back.

### Effect worker dies after external success but before recording success

The effect can be delivered again. The stable effect ID is the idempotency key. This is why effect handlers must be idempotent.

## Synchronous invocation

A direct actor method or explicit `sync` call durably enqueues a normal mailbox
message, then tries to claim that actor for the caller process. If successful,
it drains earlier messages and the target through the same activation and
executor used by workers. If another process owns the actor, the caller waits
for the row to become completed, rejected, dead-lettered, destroyed, or timed
out. Every wait re-queries durable rows. The implemented wake-up interface
provides same-process signaling, bounded polling, and dependency injection.
PostgreSQL `LISTEN/NOTIFY` and optional Redis Pub/Sub are planned adapters.

The normal path does not wait for a worker polling interval because the caller
assists execution immediately. End-to-end latency still includes earlier
mailbox work, handler execution, and database commits. When another process
owns the actor, a healthy cross-process wake-up adapter targets p99 coordination
overhead at or below 100 milliseconds; polling fallback can pay up to
`sync_polling_interval` between observations.

Caller timeout:

- Raises `SolidObjects::SyncTimeout`.
- Does not cancel or delete the message.
- Does not prevent later execution.
- Leaves the result available until retention cleanup.

The durable row remains after timeout and can be inspected directly by message ID. A public request-ID lookup and bounded retention commands are not yet implemented.

`async` performs the same durable enqueue without caller assistance or result
waiting and immediately returns a `MessageReference`. Runtime workers process
it normally.

## Domain rejection

Actor code can call `reject` for a validation or business-rule outcome that
must not retry. The executor restores pre-turn state, discards staged intents,
stores the structured rejection, completes the claimed membership, and
continues with the next sequence in one fenced transaction. Synchronous callers
receive `SolidObjects::Rejected`. A rejection is neither an exception retry nor
a dead letter.

## Effects and actor-to-actor delivery

`emit` creates a staged effect:

```ruby
emit(
  :charge_payment,
  payment_id:,
  amount_cents: total_cents,
  on_success: :payment_charged,
  on_failure: :payment_failed
)
```

An effect handler receives JSON arguments plus an effect context. Outcome messages include effect ID and a safe result or error summary.

Actor code sends to another actor through a staged outbox:

```ruby
send_to InventoryActor.ref("sku-123"), :reserve, order_id: id, quantity: 2
```

The source actor commit never waits for the target. The outbox worker allocates the target's sequence after source commit. There is no global order across actors.

## Reminders

A reminder record contains actor identity, a reminder name, target message, JSON arguments, next run time, optional interval, status, and occurrence counter.

```ruby
schedule :expire, at: 30.minutes.from_now, arguments: {}
```

When due, the scheduler locks the source instance and creates a normal mailbox
row with an idempotency key derived from reminder ID and occurrence. The
mailbox insert and reminder advancement commit atomically. The mailbox provides
sequential processing and ordinary retry behavior.

Solid Objects persists each occurrence by its mailbox row. Unlike Orleans reminders, an outage does not intentionally discard a due occurrence. Recurring catch-up is configurable:

- `:latest` enqueues the current occurrence and advances beyond the current time.
- `:all` enqueues one occurrence per scheduler pass and advances one interval, allowing bounded catch-up through ordinary scheduler work.

### Schedule reconciliation

Durable reminders are alarms, and an alarm can be lost at the application level even while the database and actor state remain healthy. A reminder callback may dead-letter, a handler may fail to schedule its successor, or a signup/configuration path may never enqueue the first message. Unlike a periodic full sweep, a self-scheduling actor can then remain silently inert forever.

Applications with self-scheduling actors should run a lower-frequency reconciliation job. The reconciler may read actor state and report drift, but it never writes actor state directly. Every repair is a normal authorized `async` invocation, so the actor decides whether the transition is still necessary and all ordering, lease, fencing, and audit rules remain intact.

`SolidObjects::Instance` exposes batchable read relations:

- `.active(actor_type:)`
- `.without_pending_work(quiet_for:)`, excluding actors with ready messages, claimed messages, or scheduled reminders
- `.orphaned(actor_type:, owner:)`, comparing actor IDs with the owner relation's primary key

The expected drift categories are actors with a lost alarm, missing actors for live owners, configuration drift, and actors whose owners were deleted. Suspended actors should be reported rather than automatically resumed unless the application defines a separate, deliberately slower recovery policy. Reconciliation metrics are the primary diagnostic: revived actors should be treated as evidence of lost alarms, while persistent bootstrap, reconfiguration, or orphan counts point to lifecycle bugs.

Bulk repair updates to `solid_objects_instances` are forbidden. They bypass activation ownership and fencing and can overwrite a concurrently committed actor state. Direct reads are observational; writes go through actor messages.

Large repairs use `async(..., available_at:)` to spread work over an application-defined dispatch window. The durable message records the requested availability and ready membership drives the hot polling query. This prevents reconciliation from flooding mailboxes and starving normal traffic.

## Realtime integration

`solid_object` performs an authorized state read for initial rendering and emits:

- A stable scope DOM ID derived from actor type and a SHA-256 digest of actor ID
- One Turbo Cable subscription element for the actor
- Stable child target IDs for values and components
- A signed actor token used by the channel subscription

```erb
<%= solid_object current_cart do |cart| %>
  Cart items: <%= cart.items_count %>
  <%= cart.component :summary %>
<% end %>
```

The signed token proves integrity, not authorization. `ActorChannel#subscribed` verifies the token, resolves the registered actor type, invokes `authorize_subscription`, and only then streams.

Broadcast replacements happen after the actor transaction commits because only a committed broadcast outbox row can be delivered. Multiple values share the same Action Cable connection and one actor subscription.

Each channel subscription transmits current observable replacements before streaming future broadcasts, including after reconnect. Missing a broadcast therefore creates temporary staleness, not permanent divergence.

## Authorization

Configuration provides five explicit policies:

- `authorize_message`
- `authorize_query`
- `authorize_destroy`
- `authorize_subscription`
- `authorize_administration`

Each receives a request context, actor type, actor ID, and relevant operation
details. A host can set request context using an isolated execution-state
carrier. Internal runtime deliveries carry a system context that is separately
recognizable.

No controller, channel, or administrative command treats an actor ID, message ID, request ID, or signed stream name as authorization.

Actor IDs are bounded UTF-8 strings and never become constant names, SQL identifiers, file paths, or raw stream names.

## Serialization

The default JSON serializer accepts:

- `nil`
- booleans
- finite numbers
- UTF-8 strings
- arrays
- objects with string or symbol keys that normalize uniquely to strings

It rejects arbitrary Ruby objects, non-finite floats, duplicate keys after normalization, excessive nesting, and values over configured byte limits.

Separate size limits exist for:

- Actor ID
- Message arguments
- Message results
- Actor state
- Effect arguments and results
- Reminder arguments
- Error backtraces

The initial release has one strict JSON serializer and no arbitrary object coercion. Versioned serializer extension points are roadmap work. Unsafe `Marshal` is not used.

## State migration and rolling deployment

An actor defines:

```ruby
state_version 2

migrate_state from: 1, to: 2 do |state|
  state["currency"] ||= "USD"
  state
end
```

Activation applies each step in order. Missing steps, cycles, non-JSON output, or stored versions newer than code fail activation.

Refusing newer stored state is a runtime invariant, not an operator recommendation. The worker does not invoke lifecycle hooks or message code when `stored_state_version > actor_class.state_version`.

Rolling deployment rules:

1. Additive code that reads old and new state can roll normally.
2. A new worker may migrate and persist state only if old workers can still read that representation.
3. If old code cannot read new state, drain old workers before enabling the migration.
4. A worker seeing a newer state version fails fast rather than guessing.
5. Actor message and observable names removed in a release must remain accepted until old queued messages and broadcast rows are drained or migrated.
6. Additive, backward-readable representation changes need no version bump.
7. Destructive changes use expand/contract releases.
8. Published actor migration steps are never squashed because dormant actors can retain old state indefinitely.

Process metadata exposes runtime and application version so operators can find mixed fleets.

## Backpressure

### Maximum mailbox length

Enqueue counts unfinished rows under the locked actor instance and rejects with `MailboxFull` above the configured limit. System outcome messages may have a reserved allowance to avoid deadlocking workflows.

### Per-actor rate limits

The initial implementation supplies the mailbox cap. Distributed token buckets or time-window counters are a hardening milestone.

### Global enqueue limits

Global admission hooks are not implemented. A future hook can reject based on database health or application policy without introducing a strict global counter as a contention hotspot.

### Payload size

Serialization validates byte size before enqueue and before commit. The configured database remains the final storage boundary.

### Slow messages

Instrumentation records execution duration. Lease renewal prevents ordinary long turns from being stolen. The pass-duration budget is checked between messages and does not preempt a running handler. Ruby code cannot be safely preempted in-process; hard termination requires process isolation.

### Hot actors and fairness

Bounded messages and activation duration force a yield. Candidate order prefers the actor whose executable membership has waited longest, and yielded due memberships move behind already-waiting work. Per-actor sequentiality means one hot actor has a natural single-actor throughput ceiling.

### Poison messages

Backoff and a retry limit prevent tight loops. The poison message blocks its actor until dead-lettered, then later messages continue.

### Handler redelivery

Sequential processing does not mean single execution. A handler can run, lose its lease before commit, and run again. Logical transitions must guard on durable state:

```ruby
def launch
  return if status == "launched"

  self.status = "launched"
  emit :launch_vehicle, launch_id: actor_id
end
```

The guard makes the state transition repeatable. The outbox commits atomically with state, and the external consumer still deduplicates by the stable effect ID.

## Deactivation

An activation becomes idle when it has no due earliest message and no turn in flight. It can remain cached for the configured idle timeout while its lease is renewed. It is released when the idle timeout is reached or the pass budget forces a fairness yield. Separate cache-pressure eviction is not implemented.

Graceful release conditionally clears owner and expiration only if the generation still matches. Expired leases need no explicit cleanup before another worker claims them.

`on_deactivate` is best effort and nondurable. It may not run on crash and cannot be the source of a correctness requirement.

## Advisory locks

PostgreSQL session-level advisory locks and MySQL named locks are not used for activations because they:

- Pin a database connection
- Couple actor lifetime to one session
- Do not persist a fencing generation
- Consume backend lock-manager resources

PostgreSQL transaction-level advisory locks may be used for optional singleton maintenance tasks, but portable row or write transactions and unique constraints are preferred when a durable record already exists.

## Transaction map

| Operation | One transaction |
| --- | --- |
| Create actor and allocate message sequence | Instance insert/lock, sequence increment, durable message and ready-membership inserts |
| Claim activation | Backend claim transaction, generation increment, owner and expiry |
| Claim next message | Move ready membership to claimed membership conditioned on lease |
| Successful message commit | Fenced state, durable message result, claimed-membership deletion, effects, reminders, actor outbox, broadcasts |
| Failed message attempt | Conditional error, claimed deletion, ready reinsertion or dead letter |
| Renew or release lease | Conditional instance update |
| Destroy actor | Instance identity lock and cascading delete of state, mailbox, reminders, and outboxes |
| Deliver reminder occurrence | Source instance lock, mailbox enqueue, and reminder advance, with a stable occurrence idempotency key |
| Claim outbox batch | Backend claim transaction and delivery ownership |
| Record outbox outcome | Success or retry/dead status |

Actor code and external network effects are never executed inside these transactions.

## Database-dependent implementations

The semantic guarantees are common, but their coordination implementations differ:

| Capability | PostgreSQL | MySQL InnoDB | SQLite |
| --- | --- | --- | --- |
| Concurrent claim | `FOR UPDATE SKIP LOCKED` | `FOR UPDATE SKIP LOCKED` | Serialized `BEGIN IMMEDIATE` |
| JSON state | JSONB | JSON | Rails JSON type |
| Executable-work indexes | Ready/claimed membership tables | Ready/claimed membership tables | Ready/claimed membership tables |
| Write isolation | Row locks and MVCC | InnoDB row/next-key locks and MVCC | One writer, serializable writes |
| Contention retry | Database/Active Record behavior; explicit classification is roadmap | Database/Active Record behavior; explicit classification is roadmap | Busy timeout; explicit busy classification is roadmap |
| Lease clock | Database current time | Database current time | Database current time |

All backends use unique identity and sequence constraints, short transactions, and conditional owner/generation/expiry fencing. Passing one backend's suite is not evidence for another.

## Answers to required correctness questions

1. **How is a per-actor sequence allocated safely?** The instance row is created uniquely, locked in the enqueue transaction, incremented, and the message inserted under a unique actor/sequence index.
2. **How is one valid activation guaranteed?** Claim atomically changes owner, creates a unique activation token, and increments generation on one locked instance row. Only the matching unexpired owner/token/generation can commit.
3. **How are stale writes rejected?** Every commit verifies owner, activation token, generation, and database-time expiration.
4. **What if a worker dies during execution?** No actor transaction remains open. After lease expiry, a new generation retries the uncommitted message.
5. **What if it dies after commit but before acknowledgement?** Completion and state are already durable, so the new activation skips that message.
6. **How are external effects retry-safe?** Effects are inserted atomically into an outbox and use a stable effect ID for handler idempotency.
7. **How are messages ordered?** Explicit per-actor sequence, earliest unfinished first.
8. **Can failed messages block later messages?** Yes, while retryable. Dead-lettering unblocks later messages.
9. **How are poison messages handled?** Bounded retries, backoff, dead letter, operator inspection and tail retry.
10. **How are hot actors prevented from monopolizing workers?** Message and duration budgets plus earliest-waiting membership scheduling and hot-actor yield.
11. **How are actors deactivated?** Idle cache timeout or eviction, best-effort hook, conditional lease release.
12. **How are leases renewed?** Conditional database update by instance, owner, generation, and unexpired lease.
13. **How does graceful shutdown work?** Stop claims, finish current turn within timeout, release cached leases, stop heartbeat, mark process stopped.
14. **How does synchronous invocation work across processes?** The caller first tries to claim and execute the actor locally. If another process owns it, a wake-up adapter prompts a durable result query and bounded polling remains the fallback.
15. **What happens after caller timeout?** The durable message continues and its eventual result remains on the message row.
16. **How are results cleaned up?** The schema has cleanup indexes, but bounded retention tooling is not implemented yet.
17. **How are large mailboxes managed?** The implemented controls are the per-actor mailbox cap, payload caps, and fair activation yields; rate and global admission controls remain roadmap work.
18. **How are completed messages pruned?** Cleanup indexes support future bounded pruning; the initial release does not automatically prune them.
19. **How are state migrations performed?** Explicit one-step actor migrations on activation, persisted only with a successful fenced commit.
20. **What happens during rolling deploys?** Newer state can make old workers incompatible; deploys must preserve backward readability or drain old workers.
21. **How are subscriptions authorized?** Verify signed identity, resolve registered type, invoke host authorization, then stream.
22. **How are lost broadcasts recovered?** Current-state refresh after reconnect; durable outbox retries server delivery.
23. **How are actor-to-actor cycles handled?** Synchronous actor waits are rejected; asynchronous request/result messages avoid call-stack cycles.
24. **Which operations are transactional?** The transaction map above lists every atomic boundary; actor code and I/O are outside.
25. **Which guarantees depend on PostgreSQL?** None of the public semantics are PostgreSQL-only. PostgreSQL and MySQL depend on row-lock claiming; SQLite depends on serialized write transactions. Each backend's guarantee depends on its adapter-specific integration tests.
