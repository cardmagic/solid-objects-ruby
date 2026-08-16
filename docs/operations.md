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

The round-trip probe runs on its own dedicated caller process rather than the
shared application caller process, and removes that record together with its
temporary actor when it finishes. Running the doctor inside a process that
already serves synchronous calls therefore leaves the application caller
process, its activations, and its claimed messages untouched, including when an
application call overlaps the probe. A database busy enough to block cleanup
reports a failed or warned check rather than raising out of the command.

## Runtime

Start all configured roles:

```bash
bundle exec solid_objects start
```

The command loads the host application's `app/actors` directories before
starting any runtime role, even when Rails eager loading is disabled. Actors in
the conventional directory do not need initializer references. The targeted
loader participates in Rails preparation callbacks so a development reload can
replace a registered actor class without loading unrelated application code.

Inspect process records and clean stale ownership:

```bash
bundle exec solid_objects status
bundle exec solid_objects cleanup
```

Process inspection, cleanup, dead-letter inspection, and retry all require an
administration policy that authorizes the CLI context:

```bash
bundle exec solid_objects prune_messages
bundle exec solid_objects prune_instances
bundle exec solid_objects prune_processes
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
- `idle_polling_interval`
- `max_mailbox_length`
- payload, state, and result byte limits
- retry attempts and delay
- heartbeat interval and alive threshold
- message retention and per-actor-type overrides
- opt-in actor-instance retention by actor type
- stopped-process retention and prune batch size

Keep lease duration comfortably above renewal interval and expected database
pause time. A handler can exceed the pass-duration budget because Ruby code is
not safely preempted; alert on message duration and isolate untrusted work.

## Polling and wake-up adapters

`polling_interval` is the fast interval after work or a wake-up. Consecutive
empty actor, effect, reminder, and broadcast passes double that role's wait up
to `idle_polling_interval`, which defaults to one second. Actor workers clamp
the ceiling to `lease_renewal_interval` while they may hold cached activations.
Set the fast and idle values equal for a fixed cadence.

The default wake-up interrupts waits only in the current Ruby process. When a
live process record shows that the database is shared across processes and no
adapter is configured, the runtime logs
`solid_objects.polling_only_cross_process_wake_up` once. Configure
`WakeUpAdapters::Postgresql` or `WakeUpAdapters::Redis` when separate processes
need prompt delivery. Without one, newly committed work can wait up to the
current idle polling interval.

The warning excludes process rows with the current hostname and PID. It can
therefore appear during a rolling deployment or restart overlap when an older
and newer process briefly share the database. A process that stopped without
graceful cleanup remains live until its heartbeat exceeds
`process_alive_threshold`; inspect `SolidObjects.administration.processes` to
distinguish a live overlap from a stale row without opening a second SQLite
connection.

Each role exposes `current_polling_interval`.
`solid_objects.polling.interval_changed` reports the role, reason, previous
interval, and current interval. The polling-only warning is also emitted as
`solid_objects.polling.only_cross_process_wake_up` instrumentation. Custom
adapters should return `true` for a notification and `false` for a timeout; an
older adapter that returns `nil` remains compatible and keeps the fast cadence.

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

## Instrumentation and logging

Active Support notifications use the `solid_objects.` prefix. Core events
include message enqueue/start/completion/failure/rejection, activation
claim/start/renew/release/deactivation failure, sync timeout/enqueue timeout/
transaction rejection, commit-action start/completion/failure, effect and
broadcast enqueue/completion, reminder enqueue, actor destruction/expiration,
retention pruning, process cleanup, and supervisor lifecycle.

`solid_objects.reminder.replaced` reports a `schedule` call that moved an alarm
already armed under the same name on the same actor, carrying the actor
identity, reminder `name`, `previous_run_at`, and `next_run_at`. Reminders are
keyed by actor and name, so re-arming a name is an update rather than a second
alarm. That is deliberate, and it is silent: an actor that arms one reminder
per queued item keeps only the last, and the earlier wake-up never happens.
Watch this event if your actors schedule from a loop or from a handler that can
run more than once. Rescheduling to the same time reports nothing.

`solid_objects.component.refreshed` covers every authorized component refresh
request. Its payload carries the actor identity, `component_name`,
`component_key`, declared `dependencies`, `refresh_method`, the rendered
`instance_id` and `revision`, and an `outcome` of `rendered`, `conflict`,
`unauthorized`, `unknown_component`, or `invalid_token`. Use it to watch
refresh rate per key, authorization denials, superseded requests, and render
duration. A rejected token reports only the outcome, since no signed identity
was recovered.

Payloads contain stable runtime identifiers, actor identity, sequence,
attempts, ownership generations, and safe exception summaries where relevant.
Arguments, component locals, actor state, results, and outbox payloads are
excluded. The bundled log subscriber turns the same notifications into
structured logger hashes.

## Retention and backups

Every actor call creates a durable message-history row, including queries and
attribute reads. The default retention policy keeps terminal message history
for 30 days and stopped process records for 7 days:

`reference.snapshot` is the explicit exception: it performs an authorized
current-state read without mailbox ordering or a message row.

```ruby
SolidObjects.configure do |configuration|
  configuration.message_retention = 30.days
  configuration.message_retention_by_actor_type = {
    "AuditActor" => 365.days,
    "EphemeralCounter" => 1.day
  }
  configuration.instance_retention_by_actor_type = {
    "EphemeralCounter" => 30.days
  }
  configuration.process_retention = 7.days
  configuration.prune_batch_size = 1_000
end
```

Both pruning commands are dry-run previews by default:

```bash
bundle exec solid_objects prune_messages
bundle exec solid_objects prune_instances
bundle exec solid_objects prune_processes
```

After reviewing the counts, execute bounded deletion:

```bash
bundle exec solid_objects prune_messages --execute
bundle exec solid_objects prune_instances --execute
bundle exec solid_objects prune_processes --execute
```

Message pruning keeps ready and claimed work, dead letters and their retry
links, messages with unfinished effects, and messages with undelivered
broadcasts. Deleting eligible history cascades to completed effects, delivered
broadcasts, and other message-owned rows. Choose a cutoff longer than every
`sync` timeout because a caller whose result row disappears can no longer
observe it.

Actor expiration is disabled by default. `prune_instances` considers only
actor types listed in `instance_retention_by_actor_type`, excludes active or
paused actors, and preserves ready/claimed mailbox work, scheduled reminders,
unfinished or dead outboxes, and dead letters. It locks and rechecks every
candidate before cascading deletion. Preview counts first, then schedule
`--execute` only after the application has accepted the loss of dormant state
and completed history.

Use authorized `reference.destroy` when deletion is an explicit application
operation rather than a retention policy.

Run stale-process `cleanup` before `prune_processes`. Normal caller processes
mark their registrations stopped at exit; hard kills remain recoverable through
heartbeat cleanup.

Back up actor tables with the same consistency guarantees as application data.
Restoring only instances without their mailboxes/outboxes, or vice versa, can
violate application expectations.
