# Solid Queue Research

## Scope and version

This research inspected the Solid Queue repository at:

- Version: `1.6.0`
- Commit: [`86f3d92f1dd68547ec0ebe960fc9933c203d9e51`](https://github.com/rails/solid_queue/tree/86f3d92f1dd68547ec0ebe960fc9933c203d9e51)
- Inspected: 2026-08-05
- Supported by that release: Ruby 3.2 or newer and Rails 7.1 or newer

Solid Queue is prior art, not a template. It coordinates independent Active Job executions. Solid Objects coordinates an ordered mailbox, state, and a renewable activation lease for one logical actor. Those are different correctness problems.

## Executive findings

The most reusable Solid Queue patterns are:

1. Keep the public API thin and put persistence and coordination in namespaced internal records.
2. Model supervisor, worker, dispatcher, and scheduler as separate process roles with small polling loops.
3. Register every runtime process in the database, heartbeat from a separate task, and prune stale registrations.
4. Claim bounded batches with `FOR UPDATE SKIP LOCKED` inside short transactions.
5. Separate scheduled work from ready work so each polling query has a narrow purpose and useful covering indexes.
6. Use database constraints as concurrency primitives, not only model validations.
7. Wrap application execution in the Rails executor and expose lifecycle hooks.
8. Instrument internal transitions with Active Support notifications and attach a dedicated log subscriber.
9. Ship an isolated engine, installer/update generators, a dummy application, process integration tests, and a small executable.
10. Treat graceful shutdown and abrupt death as different recovery paths.

The most important ideas not to reuse directly are:

1. A claimed job row is not an actor activation lease. Solid Objects needs a renewable lease and a monotonically increasing fencing generation on the actor instance.
2. Solid Queue delegates retries and argument serialization to Active Job. Solid Objects owns its message, state, result, retry, and compatibility semantics.
3. A queue-wide job priority is not a per-actor mailbox sequence.
4. Solid Queue may mark an orphaned execution failed. Solid Objects must generally make an interrupted mailbox message available again because its contract is at least once.
5. Solid Queue can execute multiple jobs with the same application identity concurrently unless a job class opts into concurrency controls. Solid Objects must make sequential execution the default invariant for every actor identity.
6. Solid Queue can disable `SKIP LOCKED` for a less concurrent fallback. Solid Objects needs explicit PostgreSQL, MySQL, and SQLite coordination adapters instead of one Boolean capability switch.
7. `safe_constantize` of a persisted class name is not acceptable for actor dispatch. Solid Objects must resolve actor types through an explicit registry.

## Repository and engine layout

### Relevant files

- [`solid_queue.gemspec`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/solid_queue.gemspec#L1-L47)
- [`lib/solid_queue.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue.rb#L1-L99)
- [`lib/solid_queue/engine.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/engine.rb#L1-L51)
- [`app/models/solid_queue/record.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/record.rb#L1-L47)
- [`config/routes.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/config/routes.rb)

### Responsibility

The gem entry point installs a Zeitwerk loader, exposes a small configuration surface, defines lifecycle hooks, and centralizes notification naming. The isolated engine connects Rails configuration, the application executor, logging, Active Job extensions, tasks, and deprecation support. Internal Active Record classes inherit from one abstract record so a separate database connection can be configured in one place.

### Apply to Solid Objects

- Use an isolated `SolidObjects::Engine`.
- Keep a single `SolidObjects::Record` connection boundary.
- Support either the primary application database or an explicit `connects_to` mapping.
- Use Zeitwerk-compatible file names and a small `lib/solid_objects.rb` entry point.
- Keep runtime records under `SolidObjects` and application actor classes outside the gem namespace.

### Do not reuse

- Do not make the engine depend on Active Job.
- Do not expose internal records as the actor programming interface.
- Do not route actor types through Rails constant lookup.

## Public API versus internal implementation

### Relevant files

- [`lib/active_job/queue_adapters/solid_queue_adapter.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/active_job/queue_adapters/solid_queue_adapter.rb#L1-L38)
- [`app/models/solid_queue/job.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/job.rb#L1-L70)
- [`lib/active_job/concurrency_controls.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/active_job/concurrency_controls.rb)

### Responsibility

The Active Job adapter is deliberately small: it translates enqueue operations to `SolidQueue::Job` persistence and reports whether the adapter is stopping. Active Job remains the user-facing abstraction. Internal job and execution records own storage transitions.

### Apply to Solid Objects

The equivalent thin public surface is:

- `SolidObjects::Actor` for definitions.
- `ActorClass.ref(actor_id)` for logical addressing.
- Direct methods and `SolidObjects::Reference#sync` for request/response
  invocation, plus `#async` for durable enqueue.
- Explicit helpers for reminders, effects, observables, and lifecycle hooks.

Mailbox rows, leases, worker records, and outboxes remain internal. Public message and dead-letter references should expose identifiers and safe inspection methods without leaking Active Record mutation APIs.

### Do not reuse

Active Job serialization, callbacks, retry DSL, job class lookup, and queue semantics do not define the Solid Objects contract. Actor messages need a purpose-built envelope and actor-wide ordering.

## Process lifecycle and supervision

### Relevant files

- [`lib/solid_queue/supervisor.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/supervisor.rb#L1-L149)
- [`lib/solid_queue/fork_supervisor.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/fork_supervisor.rb#L1-L88)
- [`lib/solid_queue/async_supervisor.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/async_supervisor.rb#L1-L52)
- [`lib/solid_queue/processes/base.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/processes/base.rb#L1-L47)
- [`lib/solid_queue/processes/runnable.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/processes/runnable.rb#L1-L183)
- [`lib/solid_queue/processes/supervised.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/processes/supervised.rb#L1-L40)

### Responsibility

The supervisor validates configuration, starts configured process roles, runs a maintenance task, watches child processes or threads, replaces unexpected exits, and coordinates graceful or immediate termination. Fork mode uses operating-system processes and signals. Async mode uses supervised threads. Runnable processes share boot, shutdown, signal, and liveness behavior.

### Apply to Solid Objects

- Use one supervisor abstraction with worker, reminder scheduler, effect worker, and broadcast worker roles.
- Prefer forked role processes for isolation, with an inline/thread mode for development and tests.
- Wrap process work in `Rails.application.executor`.
- Make shutdown two-phase: stop claiming new actors, allow in-flight message transactions to finish, release owned leases, then deregister.
- Replace crashed children, but rely on database leases and fencing for correctness.

### Do not reuse

Process supervision must not be the correctness boundary. A worker can pause without exiting, so process PID checks and heartbeat pruning cannot prevent stale writes. Only a conditional fenced state update can do that.

## Workers, dispatchers, and schedulers

### Relevant files

- [`lib/solid_queue/worker.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/worker.rb#L1-L66)
- [`lib/solid_queue/dispatcher.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/dispatcher.rb#L1-L60)
- [`lib/solid_queue/scheduler.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/scheduler.rb#L1-L76)
- [`lib/solid_queue/processes/poller.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/processes/poller.rb#L1-L54)

### Responsibility

Workers claim ready executions up to their available execution capacity and submit them to a bounded pool. Dispatchers move due scheduled executions to ready executions in batches. Schedulers create recurring jobs. Pollers return their next delay, enabling immediate follow-up when a batch was full and configured sleep when no work was found.

### Apply to Solid Objects

- Actor workers claim actor identities, not arbitrary messages.
- A worker drains a bounded number of messages for one actor before yielding.
- Reminder scheduling, effects, and broadcasts remain separate roles with narrow polling queries.
- Poll immediately while a batch remains full and back off to the configured interval when no work is found.
- Wake an idle poller after local enqueue; use a pluggable cross-process hint where the host application needs tighter latency.

### Refine for Solid Objects

Solid Queue demonstrates an especially reusable portability pattern here: durable job history is separate from narrow ready and claimed execution membership. Solid Objects should retain one durable actor-message row, while ready and claimed membership live in small hot tables. This avoids a status-dependent polling index that grows with completed history and works consistently across PostgreSQL, MySQL, and SQLite.

Durable reminders still have their own definitions because recurrence has lifecycle beyond a delayed message. When a reminder fires, its ordinary actor message enters durable history plus ready membership.

## Database polling and safe claiming

### Relevant files

- [`app/models/solid_queue/record.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/record.rb#L12-L19)
- [`app/models/solid_queue/ready_execution.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/ready_execution.rb#L9-L44)
- [`app/models/solid_queue/claimed_execution.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/claimed_execution.rb#L14-L27)
- [`app/models/solid_queue/scheduled_execution.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/scheduled_execution.rb#L1-L25)

### Responsibility

`Record.non_blocking_lock` selects `FOR UPDATE SKIP LOCKED` when supported. Ready executions are ordered, selected and locked in a short transaction, inserted into the claimed table, then deleted from ready. Scheduled executions use the same bounded non-blocking lock pattern.

### Apply to Solid Objects

Use `FOR UPDATE SKIP LOCKED` on PostgreSQL and MySQL for:

- Selecting candidate actor instance rows whose earliest mailbox message is due and whose lease is free or expired.
- Claiming due reminders.
- Claiming pending outbox effects and broadcasts.
- Pruning stale processes in bounded batches.

Actor activation claim must atomically update:

- `activation_owner_id`
- `activation_expires_at`
- `activation_generation = activation_generation + 1`

and return the new generation. The generation is the fencing token.

SQLite must instead enter a write transaction with `BEGIN IMMEDIATE`, select a bounded candidate, and update its generation before commit. SQLite serializes writers database-wide, so it preserves correctness with lower concurrency.

### Do not reuse

Do not claim several messages for the same actor into independent execution records. Claim one actor, then move only its earliest eligible ready membership to claimed membership. Do not hold the candidate row lock or SQLite write transaction while running actor code.

## Polling query performance

### Relevant files

- [`app/models/solid_queue/queue_selector.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/queue_selector.rb#L1-L98)
- [`app/models/solid_queue/record/distinct_values.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/record/distinct_values.rb#L1-L50)
- [`README.md`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/README.md#queues-specification-and-performance)

### Responsibility

Solid Queue constrains polling to index-friendly forms. Its PostgreSQL path emulates a loose index scan with a recursive CTE when discovering distinct queue names because PostgreSQL otherwise scans a large leading-index range.

### Apply to Solid Objects

- Avoid `DISTINCT actor_type` discovery in the hot path.
- Keep candidate selection driven by the small ready-membership table and an ordinary composite index.
- Use bounded limits and deterministic ordering.
- Measure query plans in PostgreSQL integration tests and benchmark scripts.

### Do not reuse

Solid Objects has no named queue selection API in v1, so the queue selector and recursive CTE are unnecessary. Actor type filters can be added later only with measured indexes.

## Process registration, heartbeats, and cleanup

### Relevant files

- [`lib/solid_queue/processes/registrable.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/processes/registrable.rb#L1-L67)
- [`app/models/solid_queue/process.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/process.rb#L1-L47)
- [`app/models/solid_queue/process/prunable.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/process/prunable.rb#L1-L32)
- [`lib/solid_queue/supervisor/maintenance.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/supervisor/maintenance.rb#L1-L47)

### Responsibility

Each process receives a random name, registers kind, PID, hostname, supervisor, metadata, and heartbeat time, then heartbeats on an independent timer. The supervisor periodically locks and prunes stale process rows in small batches. Pruning finalizes or releases work associated with the dead process.

### Apply to Solid Objects

- Store a UUID worker ID separate from PID.
- Record kind, hostname, PID, metadata, started time, last heartbeat, and shutdown state.
- Heartbeat independently of mailbox execution so a hot or slow actor does not suppress liveness.
- On stale worker cleanup, clear expired leases only through a generation-changing acquisition or explicit conditional release.
- Retain process rows briefly for diagnostics rather than using deletion as the only state transition.

### Do not reuse

A live process heartbeat does not prove an activation is live, and an expired process heartbeat does not itself authorize a stale worker write. Process state and activation lease state must remain separate.

## Concurrency controls

### Relevant files

- [`lib/active_job/concurrency_controls.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/active_job/concurrency_controls.rb)
- [`app/models/solid_queue/job/concurrency_controls.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/job/concurrency_controls.rb#L1-L78)
- [`app/models/solid_queue/semaphore.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/semaphore.rb#L1-L96)
- [`app/models/solid_queue/blocked_execution.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/blocked_execution.rb)

### Responsibility

Solid Queue implements optional job concurrency limits with database semaphores. Unique keys, conditional updates, expiration, and blocked execution rows control how many matching jobs may become ready.

### Apply to Solid Objects

The useful lesson is to combine unique indexes, conditional updates, and explicit recovery records. Backpressure and global/per-actor admission limits can later use similarly narrow counters.

### Do not reuse

Actor sequentiality is not a semaphore feature. It is a mandatory lease plus fenced-commit invariant. A semaphore with expiry but no fencing token permits a paused owner to resume and write stale state.

## Retry, failure, and recovery

### Relevant files

- [`app/models/solid_queue/claimed_execution.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/claimed_execution.rb#L64-L125)
- [`app/models/solid_queue/job/retryable.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/job/retryable.rb#L1-L38)
- [`app/models/solid_queue/failed_execution.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/app/models/solid_queue/failed_execution.rb#L1-L81)
- [`lib/solid_queue/supervisor/maintenance.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/supervisor/maintenance.rb#L30-L45)

### Responsibility

Claim finalization locks the claim row so a stale performer cannot finish after pruning won the race. Failures persist structured exception data. Active Job decides automatic retries; Solid Queue exposes manual retry and dead process cleanup.

### Apply to Solid Objects

- Final message completion and actor state update must occur in one transaction.
- The state update predicate must include actor instance ID, owner process ID, and activation generation.
- On actor-code failure, roll back state and effects, then record the attempt and retry schedule in a separate transaction.
- After the retry limit, atomically create a dead letter and mark the mailbox message dead.
- Preserve exception class, message, bounded backtrace, first/last failure times, and attempts.
- A worker crash before commit leaves the message pending or processing with an expired lease; the next generation retries it.
- A crash after the state/message transaction commits needs no message retry because completion is already durable.

### Do not reuse

Do not describe retries as exactly once. An external effect can happen before a process dies and before its success is recorded. Effect handlers and actor message code that escapes the state transaction must be idempotent.

## Configuration loading

### Relevant files

- [`lib/solid_queue/configuration.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/configuration.rb#L1-L329)
- [`lib/generators/solid_queue/install/templates/config/queue.yml`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/generators/solid_queue/install/templates/config/queue.yml)

### Responsibility

Solid Queue combines global Rails options with environment-specific YAML process definitions, validates incompatible options, supplies defaults, warns about connection pool sizing, and supports environment variables and CLI overrides.

### Apply to Solid Objects

- Use `config.solid_objects` for library behavior and `config/actors.yml` for process topology.
- Validate lease duration greater than renewal interval, positive batch limits, idle timeout, pool capacity, retry limits, and payload sizes.
- Keep defaults conservative and explicit.
- Support per-role process counts and polling intervals.
- Provide `solid_objects check`.

### Do not reuse

Do not allow configuration to weaken fencing or disable PostgreSQL correctness requirements. Unsafe combinations must fail fast rather than warn.

## Logging and instrumentation

### Relevant files

- [`lib/solid_queue.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue.rb#L23-L44)
- [`lib/solid_queue/log_subscriber.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/log_subscriber.rb#L1-L186)
- [`test/integration/instrumentation_test.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/test/integration/instrumentation_test.rb)

### Responsibility

Internal operations call one instrumentation helper that emits `event.solid_queue`. A dedicated `ActiveSupport::LogSubscriber` formats events with the gem version, duration, identifiers, sizes, and safe error summaries. Poll SQL logging can be silenced without hiding notification events.

### Apply to Solid Objects

- Emit the specified `solid_objects.*` notification names.
- Include actor type, a one-way actor identity digest by default, message ID, request ID, sequence, attempt, process ID, lease generation, duration, and outcome.
- Exclude actor IDs, arguments, state, results, and effect payloads by default.
- Use structured hashes when the configured logger supports them, with readable text fallback.
- Test event names and payload redaction.

### Do not reuse

Do not log raw actor identity, message arguments, state, or results merely because they are in database rows.

## Migrations and schema organization

### Relevant files

- [`lib/generators/solid_queue/install/install_generator.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/generators/solid_queue/install/install_generator.rb#L1-L22)
- [`lib/generators/solid_queue/install/templates/db/queue_schema.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/generators/solid_queue/install/templates/db/queue_schema.rb#L1-L129)
- [`lib/generators/solid_queue/update/update_generator.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/generators/solid_queue/update/update_generator.rb)

### Responsibility

The installer creates a process executable, YAML configuration, and a complete queue schema suitable for a separate database. Updates later ship as migrations. The schema uses narrow execution-state tables, unique indexes, and cascading foreign keys.

### Apply to Solid Objects

- Ship normal engine migrations under `db/migrate`.
- Provide `solid_objects:install:migrations` and an install generator.
- Keep a configurable table prefix but generate concrete table names at migration install time.
- Use PostgreSQL JSONB, MySQL JSON, and SQLite JSON-compatible columns, with portable check constraints and foreign keys.
- Put live execution membership in narrow ready and claimed tables with ordinary composite indexes on every supported backend.
- Document every index and the query it supports.

### Refine for Solid Objects

Do not duplicate the durable envelope across execution tables. Keep the envelope and result history in `solid_objects_messages`, and represent only current execution membership in `solid_objects_ready_messages` or `solid_objects_claimed_messages`. Dead letters retain terminal diagnostics. This preserves one inspectable message history while keeping hot indexes small.

## Command-line entry points

### Relevant files

- [`lib/solid_queue/cli.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/cli.rb#L1-L44)
- [`lib/generators/solid_queue/install/templates/bin/jobs`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/generators/solid_queue/install/templates/bin/jobs)
- [`lib/solid_queue/tasks.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/lib/solid_queue/tasks.rb)

### Responsibility

The Thor CLI has a default `start` command and a non-mutating configuration check. The generated application executable loads Rails and invokes the gem CLI. Rake tasks install and update configuration and schema.

### Apply to Solid Objects

Provide:

- `solid_objects start`
- `solid_objects check`
- `solid_objects status`
- `solid_objects dead-letters`
- `solid_objects retry-dead-letter ID`
- `solid_objects prune`

The gem executable loads the host application. Operational mutations require explicit identifiers and should report exactly what changed.

## Testing patterns

### Relevant files

- [`test/test_helper.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/test/test_helper.rb)
- [`test/test_helpers/processes_test_helper.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/test/test_helpers/processes_test_helper.rb)
- [`test/models/solid_queue/claimed_execution_concurrency_test.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/test/models/solid_queue/claimed_execution_concurrency_test.rb)
- [`test/integration/forked_processes_lifecycle_test.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/test/integration/forked_processes_lifecycle_test.rb)
- [`test/integration/async_processes_lifecycle_test.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/test/integration/async_processes_lifecycle_test.rb)
- [`test/integration/jobs_lifecycle_test.rb`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/test/integration/jobs_lifecycle_test.rb)

### Responsibility

Solid Queue uses Minitest, fixtures, a dummy Rails application, unit tests for role objects, integration tests with real child processes, and concurrency tests using separate connections. Concurrency tests disable transactional wrapping when distinct database sessions are required. Process helpers bypass the Active Record query cache while observing writes from other processes.

### Apply to Solid Objects

- Use Minitest and a dummy Rails app.
- Run PostgreSQL-only locking tests on separate checked-out connections.
- Disable transactional tests only where concurrency requires it and clean rows explicitly.
- Prefer barriers, queues, latches, and condition variables to arbitrary sleeps.
- Verify stale writer rejection by pausing generation A after its lease expires, committing generation B, then allowing A to attempt its conditional update.
- Test real forks for crash recovery and graceful shutdown.
- Inspect database state without the query cache during cross-process assertions.

### Do not reuse

Do not treat one backend's tests as evidence for another. PostgreSQL and MySQL need real row-lock and `SKIP LOCKED` tests. SQLite needs real `BEGIN IMMEDIATE`, busy-retry, and serialized-writer tests.

## Formatting policy

### Relevant files

- [`.rubocop.yml`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/.rubocop.yml)
- [`solid_queue.gemspec`](https://github.com/rails/solid_queue/blob/86f3d92f1dd68547ec0ebe960fc9933c203d9e51/solid_queue.gemspec)

Solid Queue inherits `rubocop-rails-omakase`, targets Ruby 3.3, and excludes generated schema files plus update-generator database templates. Solid Objects carries that exact `.rubocop.yml` policy and runs it as a required gate. Standard Ruby is retained as a second gate; only Standard's two array/hash interior-whitespace cops are ignored because they directly contradict Rails Omakase.

## PostgreSQL-specific conclusions

### `FOR UPDATE SKIP LOCKED`

PostgreSQL documents `SKIP LOCKED` as an intentionally inconsistent view suitable for queue-like multi-consumer access. It skips rows that cannot be locked immediately and still takes the ordinary table-level lock. Solid Objects should use it only to distribute candidate actor and outbox records. It must not define actor ordering or correctness by itself.

Source: [PostgreSQL 18 `SELECT`, locking clause](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)

### Advisory locks

PostgreSQL advisory locks have application-defined meaning. Session-level locks survive transaction rollback and require a pinned database session until release. Transaction-level locks end with the transaction.

Solid Objects should not use session advisory locks for activation ownership because that would pin a Rails connection for the activation lifetime and still would not provide a persisted fencing generation. Row leases with conditional fenced updates are sufficient. Transaction advisory locks may be an optional optimization for rare, short administrative operations such as ensuring a single cleanup pass, but they are not part of message correctness.

Source: [PostgreSQL 18 explicit locking, advisory locks](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS)

### `LISTEN` and `NOTIFY`

`LISTEN` is session-scoped and has a startup race that PostgreSQL explicitly addresses by requiring the listener to commit `LISTEN`, inspect database state, then treat notifications as hints about later changes. `NOTIFY` is delivered only after commit, may coalesce duplicate payloads in one transaction, has a payload size limit, and only reaches sessions listening at delivery time.

Solid Objects should place durable work in tables first and optionally send a small notification containing a shard or actor digest. Every wake-up path must re-query the database. Polling remains the correctness path.

Sources:

- [PostgreSQL 18 `LISTEN`](https://www.postgresql.org/docs/current/sql-listen.html)
- [PostgreSQL 18 `NOTIFY`](https://www.postgresql.org/docs/current/sql-notify.html)

## MySQL-specific conclusions

MySQL 8 InnoDB supports transactional row-level locking and `FOR UPDATE SKIP LOCKED`. Like PostgreSQL, MySQL documents the resulting view as inconsistent but suitable for queue-like consumers. MySQL locking reads require an explicit transaction. Index choice matters because InnoDB locks index records encountered by the scan and can take gap locks.

Solid Objects should require MySQL 8 with InnoDB, use exact claim indexes, keep transactions short, and retry deadlocks. Ready and claimed membership tables avoid any dependency on partial indexes.

Sources:

- [MySQL 8.4 InnoDB locking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html)
- [MySQL 8.4 InnoDB locking](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)

## SQLite-specific conclusions

SQLite allows multiple readers but only one writer. `BEGIN IMMEDIATE` acquires the write transaction before the first read and avoids a later read-snapshot upgrade failure. SQLite reports contention as `SQLITE_BUSY`, which requires bounded retry. SQLite 3.35 and newer supports `RETURNING`.

Solid Objects can preserve its lease and fencing contract on SQLite by serializing short coordination writes with `BEGIN IMMEDIATE`. It cannot provide PostgreSQL/MySQL claim throughput because all writers share the database-wide serialization point.

Sources:

- [SQLite transactions](https://www.sqlite.org/lang_transaction.html)
- [SQLite isolation](https://www.sqlite.org/isolation.html)
- [SQLite `RETURNING`](https://www.sqlite.org/lang_returning.html)

## Inline RBS prior art from Classifier

The current `cardmagic/classifier` source uses RBS::Inline directly in Ruby files:

- [`lib/classifier/bayes.rb`](https://github.com/cardmagic/classifier/blob/48cdfa63f3efdba8149c8f47dd053ceebce5dfc1/lib/classifier/bayes.rb) begins with `# rbs_inline: enabled`, declares instance variables with `# @rbs @name: Type`, and places full `# @rbs (...) -> Return` signatures immediately before methods.
- [`classifier.gemspec`](https://github.com/cardmagic/classifier/blob/48cdfa63f3efdba8149c8f47dd053ceebce5dfc1/classifier.gemspec) includes `rbs-inline` as a development dependency and packages generated `sig/**/*.rbs`.
- [`.github/workflows/ruby.yml`](https://github.com/cardmagic/classifier/blob/48cdfa63f3efdba8149c8f47dd053ceebce5dfc1/.github/workflows/ruby.yml) generates signatures, validates them with RBS, and runs Steep.
- [`Steepfile`](https://github.com/cardmagic/classifier/blob/48cdfa63f3efdba8149c8f47dd053ceebce5dfc1/Steepfile) enables strict diagnostics for the typed library while explicitly isolating incompatible extension files.

Solid Objects will use the same source-adjacent convention. Every owned Ruby source file starts with `# rbs_inline: enabled`, declares its instance variables, and annotates public and private methods. Generated signatures are checked rather than hand-maintained as a competing source of truth.

## Related primary-source findings

### Orleans virtual actors

Orleans grain identity is a type plus key. An activation is an on-demand in-memory embodiment of that logical identity and can be collected after idleness. Default non-reentrant grains process a request to completion before starting the next request. Cyclic synchronous calls can deadlock. Orleans timers belong to an activation and disappear with it; reminders are durable definitions associated with a logical grain and reactivate it.

Solid Objects adopts logical identity, on-demand activation, sequential turns, idle deactivation, and durable reminders. It does not copy Orleans delivery semantics: Orleans defaults to at most once unless retry behavior changes that result, while Solid Objects deliberately persists a mailbox and provides at least once.

Sources:

- [Orleans grain directory](https://learn.microsoft.com/en-us/dotnet/orleans/host/grain-directory)
- [Orleans activation collection](https://learn.microsoft.com/en-us/dotnet/orleans/host/configuration-guide/activation-collection)
- [Orleans request scheduling](https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling)
- [Orleans delivery guarantees](https://learn.microsoft.com/en-us/dotnet/orleans/implementation/messaging-delivery-guarantees)
- [Orleans timers and reminders](https://learn.microsoft.com/en-us/dotnet/orleans/grains/timers-and-reminders)
- [Orleans rolling grain upgrades](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-versioning/deploying-new-versions-of-grains)

### Transactional outbox

The outbox pattern replaces an unreliable dual write with one database transaction that changes business state and inserts a durable delivery record. A separate relay delivers and marks the record. Relay delivery remains at least once, so consumers need idempotency.

Solid Objects uses the actor message commit transaction to save fenced state, complete the message, and insert effects and broadcasts. Separate workers deliver outbox rows.

Source: [Microsoft Azure Architecture Center, transactional outbox](https://learn.microsoft.com/en-us/azure/architecture/databases/guide/transactional-out-box-cosmos)

### Rails engines

Rails isolated engines namespace models, controllers, views, routes, and helpers. Engine migrations are copied into the host and then run in the host application's database context.

Solid Objects uses isolation for its administrative and realtime integration surface. Actor classes remain host application classes registered through the gem API.

Source: [Rails Engines Guide](https://guides.rubyonrails.org/engines.html)

### Action Cable and Turbo Streams

Action Cable multiplexes channel subscriptions over a connection. Broadcastings are online-only: disconnected consumers miss them. A channel must authorize the actor identity before calling `stream_from`. Realtime payloads therefore need a durable broadcast outbox plus a reconnect refresh path that reads current actor state.

Source: [Rails Action Cable Guide](https://guides.rubyonrails.org/action_cable_overview.html)

### Cloudflare Durable Objects

Durable Objects combine a globally unique logical object, on-demand lifecycle, single-threaded execution, and object-local strongly consistent storage in a managed serverless runtime.

Solid Objects offers a related programming shape inside Rails but has materially different operational properties: shared SQL tables, explicit worker processes, application-managed deployments, database polling, at-least-once mailbox execution, and no globally placed compute/storage unit per actor.

Source: [Cloudflare Durable Objects overview](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/)

## Assumptions and version-sensitive behavior

- Solid Queue findings are tied to v1.6.0. Earlier releases did not have all current async/fiber supervision and concurrency finalization behavior.
- PostgreSQL documentation inspected was current PostgreSQL 18 documentation. `SKIP LOCKED` has existed since PostgreSQL 9.5, but Solid Objects supports PostgreSQL 14 and newer.
- MySQL documentation inspected was MySQL 8.4. Solid Objects supports MySQL 8.0 and newer with InnoDB.
- SQLite documentation inspected covers current SQLite behavior. Solid Objects requires SQLite 3.35 or newer for `RETURNING` support.
- Rails documentation and source inspected cover Rails 8.1. Solid Objects requires Rails 7.1 or newer. Rails 8 changed the SQLite adapter's default write transaction from deferred to immediate, and the test suite also passes on Rails 7.1 and 7.2 with the deferred default. Rails 7.0 stays out of range because its SQLite adapter requires sqlite3 1.4, and the busy-handler control this gem depends on arrived in sqlite3 2.x.
- Orleans documentation describes current Orleans behavior, not a compatibility promise for this Ruby implementation.
- `LISTEN/NOTIFY` and Action Cable are optimizations and delivery channels, never durable truth.
- A separate actor database is compatible only when all rows participating in an atomic actor commit, including message, state, effects, and broadcasts, live in that same actor database.

## Design consequences for Solid Objects

1. One instance row exists for each registered `actor_type` and `actor_id`.
2. Concurrent enqueue locks that instance row, increments `next_message_sequence`, and inserts the mailbox row in one transaction.
3. PostgreSQL and MySQL workers use `SKIP LOCKED` only to select actor candidates; SQLite serializes claim writes with `BEGIN IMMEDIATE`.
4. Claiming an actor increments its activation generation and records owner and expiry.
5. Actor code runs without holding a transaction or checked-out connection.
6. Each message commit opens a short transaction, locks the instance row, verifies owner and generation, saves state, completes the message, and inserts outbox rows.
7. Losing the fenced update means the worker discards its in-memory result and does not finalize the message.
8. A bounded activation pass and oldest-pending-first candidate order provide fairness.
9. Process heartbeats support operations and cleanup but do not replace activation leases.
10. Realtime notifications and `LISTEN/NOTIFY` can reduce latency only after durable rows commit.
