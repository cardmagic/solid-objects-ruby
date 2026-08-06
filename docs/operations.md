# Operations guide

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
but sends every repair through `tell`.

Use:

- `Instance.states_for(actor_type:, actor_ids:)`;
- `Instance.active(actor_type:)`;
- `Instance.without_pending_work(quiet_for:)`;
- `Instance.orphaned(actor_type:, owner:)`.

Spread large repairs with `available_at:`. Report at least bootstrapped,
reconfigured, revived, suspended, and orphaned counts. A nonzero revived count
is evidence that alarms are being lost.

Never bulk-update actor state. That bypasses lease ownership and fencing.

## Monitoring

Alert on:

- oldest ready-message age;
- ready and claimed membership counts;
- mailbox-full rejections;
- actor turn duration and failures;
- lost-activation rate;
- dead-letter creation;
- stale process heartbeats;
- effect and broadcast retry/dead counts;
- due-reminder lag;
- reconciliation drift;
- database lock waits, deadlocks, and SQLite busy errors.

## Retention and backups

The schema has cleanup indexes, but automatic pruning commands are still
roadmap work. Until implemented, define application-owned bounded deletes that
preserve unfinished messages, dead letters under investigation, and ask results
for the promised lookup period.

Back up actor tables with the same consistency guarantees as application data.
Restoring only instances without their mailboxes/outboxes, or vice versa, can
violate application expectations.
