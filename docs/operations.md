# Operations guide

## Installation verification

Run the installation doctor after generating the initializer and migrating:

```bash
bin/rails solid_objects:doctor
```

It validates runtime configuration, required tables and columns, neutral policy
posture, live runtime roles, and a real workerless synchronous actor round-trip.
Engine migration timestamps are rewritten when copied into a host application,
so the schema check compares the required shape instead of a fixed timestamp.
Warnings such as an all-deny neutral policy do not fail the command because a
context-aware production policy may correctly deny the probe.

## Runtime

Start all configured roles:

```bash
bundle exec solid_objects start
```

Inspect process records and clean stale ownership:

```bash
bundle exec solid_objects status
bundle exec solid_objects cleanup
```

Process inspection, cleanup, dead-letter inspection, and retry all require an
administration policy that authorizes the CLI context:

```bash
bundle exec solid_objects dead_letters
bundle exec solid_objects retry_dead_letter 123
```

## Configuration

Important controls include:

- `worker_count`
- `effect_worker_count`
- `broadcast_worker_count`
- `reminder_scheduler_count`
- `max_messages_per_activation_pass`
- `max_activation_duration`
- `idle_deactivation_timeout`
- `lease_duration`
- `lease_renewal_interval`
- `polling_interval`
- `max_mailbox_length`
- payload, state, and result byte limits
- retry attempts and delay
- heartbeat interval and alive threshold

Keep lease duration comfortably above renewal interval and expected database
pause time. A handler can exceed the pass-duration budget because Ruby code is
not safely preempted; alert on message duration and isolate untrusted work.

## Graceful shutdown

The supervisor requests shutdown, stops new claims, lets active loops return,
releases cached actor leases, and marks process rows stopped. A hard kill is
safe: claimed messages become recoverable when the lease or process heartbeat
is stale.

Automatic replacement of failed runtime threads and periodic cleanup inside the
supervisor are not implemented yet. Run the cleanup command from a scheduled
operational task until that roadmap item lands.

## Reconciliation

Self-scheduling actors need a daily or similarly low-frequency reconciliation
job because an application-level alarm can be lost. The reconciler reads state
but sends every repair through `async`.

Use:

- `Instance.states_for(actor_type:, actor_ids:)`;
- `Instance.active(actor_type:)`;
- `Instance.without_pending_work(quiet_for:)`;
- `Instance.orphaned(actor_type:, owner:)`.

Spread large repairs with `available_at:`. Report at least bootstrapped,
reconfigured, revived, suspended, and orphaned counts. A nonzero revived count
is evidence that alarms are being lost.

Never bulk-update actor state. That bypasses lease ownership and fencing.

## Actor destruction

Delete an actor only through its authorized reference:

```ruby
Counter.ref("global").destroy(authorization_context: Current.user)
```

Do not delete `solid_objects_instances` directly. The public operation locks
the identity, invalidates stale activations through the deleted incarnation
key, cascades through all actor-owned rows, emits
`solid_objects.actor.destroyed`, and wakes local waiters.

Destruction removes pending outboxes but cannot recall external I/O,
actor-to-actor delivery, or a broadcast that already started. Confirm
downstream idempotency and application retention requirements before deleting
an actor. Reusing the same actor type and ID creates a fresh incarnation.

## Monitoring

Alert on:

- oldest ready-message age;
- ready and claimed membership counts;
- mailbox-full rejections;
- actor turn duration and failures;
- lost-activation rate;
- dead-letter creation;
- actor destruction rate;
- stale process heartbeats;
- effect and broadcast retry/dead counts;
- due-reminder lag;
- reconciliation drift;
- database lock waits, deadlocks, and SQLite busy errors.

## Retention and backups

The schema has cleanup indexes, but automatic pruning commands are still
roadmap work. Every actor call creates a durable message-history row, including
queries and attribute reads. Choose a retention period from measured call
volume, storage budget, audit needs, and the longest promised synchronous-result
lookup window.

An application-owned pruning job can start from this conservative relation:

```ruby
cutoff = 30.days.ago

prunable_messages = SolidObjects::Message
  .where(completed_at: ...cutoff)
  .where.not(id: SolidObjects::ReadyMessage.select(:message_id))
  .where.not(id: SolidObjects::ClaimedMessage.select(:message_id))
  .where.not(id: SolidObjects::DeadLetter.select(:message_id))
  .where.not(
    id: SolidObjects::DeadLetter
      .where.not(retried_message_id: nil)
      .select(:retried_message_id)
  )
  .where.not(
    id: SolidObjects::Effect
      .where.not(status: "completed")
      .select(:message_id)
  )
  .where.not(
    id: SolidObjects::Broadcast
      .where.not(status: "delivered")
      .select(:message_id)
  )

prunable_messages.in_batches(of: 1_000).delete_all
```

Deleting a message cascades to its completed effects, delivered broadcasts, and
other message-owned records. Test the exact relation against a restored
production snapshot before scheduling it. Keep source and retried messages for
dead letters under investigation, and never prune pending, processing, ready, or
claimed work. Choose a cutoff longer than every `sync` timeout because a caller
whose result row disappears can no longer observe that result.

Back up actor tables with the same consistency guarantees as application data.
Restoring only instances without their mailboxes/outboxes, or vice versa, can
violate application expectations.
