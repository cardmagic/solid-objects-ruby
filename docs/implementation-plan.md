# Solid Objects Implementation Plan

## Test-driven workflow

Every behavior change starts with a focused failing Minitest, followed by the smallest implementation that makes it pass and a refactor while green. The suite follows Solid Queue's organization:

- `test/unit` for actor DSL and pure value objects
- `test/models` for records, constraints, and query objects
- `test/integration` for end-to-end runtime and process behavior
- `test/test_helpers` for deterministic barriers, process control, and cross-connection observation
- `test/dummy` for a real host Rails application and engine integration

Core coordination tests use real PostgreSQL, MySQL, and SQLite connections. Tests that require independent sessions do not use transactional wrapping and clean their records explicitly. Race tests use barriers, queues, condition variables, or child-process pipes rather than timing-based sleeps as their primary synchronization.

## Milestone 0: Gem, inline RBS, and database test harness

### Files

- `solid_objects.gemspec`
- `Gemfile`
- `Rakefile`
- `lib/solid_objects.rb`
- `lib/solid_objects/version.rb`
- `lib/solid_objects/engine.rb`
- `test/dummy/**`
- `test/test_helper.rb`
- `.github/workflows/ci.yml`
- `.standard.yml`
- `Steepfile`
- `sig/**`

### Public API

`SolidObjects.configure` and `SolidObjects::VERSION`. All owned Ruby files use `# rbs_inline: enabled`, instance-variable declarations, and method signatures following `cardmagic/classifier`.

### Database changes

None.

### Tests

- Engine boots in the dummy application.
- PostgreSQL, MySQL InnoDB, and SQLite adapters and minimum server versions are validated.
- Zeitwerk eager loading succeeds.
- RBS::Inline generation, RBS validation, and Steep checking succeed.

### Failure modes

- Rails or Ruby outside the supported range.
- Missing `pg` adapter.
- Missing `mysql2` or `sqlite3` adapter in its matrix job.
- Test database unavailable.

### Completion criteria

Bundle installs, each dummy database boots, and the empty Minitest suite, Standard Ruby, generated RBS validation, and Steep pass.

## Milestone 1: Registry, actor DSL, state, and serialization

### Files

- `lib/solid_objects/actor.rb`
- `lib/solid_objects/actor_registry.rb`
- `lib/solid_objects/actor_definition.rb`
- `lib/solid_objects/state.rb`
- `lib/solid_objects/serialization.rb`
- `lib/solid_objects/context.rb`
- `lib/solid_objects/errors.rb`
- `test/unit/actor_registry_test.rb`
- `test/unit/actor_test.rb`
- `test/unit/state_test.rb`
- `test/unit/serialization_test.rb`

### Public API

- `SolidObjects::Actor`
- `actor_type`
- `attribute` with actor instance readers and writers
- Public instance methods as messages
- `message` for explicit dynamic definitions
- `query`, `observable`
- `state_version`, `migrate_state`
- `on_activate`, `on_deactivate`
- `ActorClass.ref(actor_id)`

### Database changes

None.

### Tests

- Registration and duplicate rejection
- Public, private, query, and observable method lookup
- Defaults are not shared
- JSON normalization and unsafe value rejection
- Complete state migration chains and newer-state rejection

### Failure modes

- Anonymous or duplicate actor types
- Undefined message names
- Mutable defaults shared across actors
- Unsafe serialization
- Missing migration step

### Completion criteria

Actor definitions can be instantiated and executed in memory without persistence or constantization.

## Milestone 2: Portable schema and internal records

### Files

- `db/migrate/001_create_solid_objects_tables.rb`
- `app/models/solid_objects/record.rb`
- `app/models/solid_objects/instance.rb`
- `app/models/solid_objects/message.rb`
- `app/models/solid_objects/ready_message.rb`
- `app/models/solid_objects/claimed_message.rb`
- `app/models/solid_objects/reminder.rb`
- `app/models/solid_objects/effect.rb`
- `app/models/solid_objects/broadcast.rb`
- `app/models/solid_objects/dead_letter.rb`
- `app/models/solid_objects/process.rb`
- `lib/solid_objects/database_adapter.rb`
- `lib/solid_objects/database_adapters/postgresql.rb`
- `lib/solid_objects/database_adapters/mysql.rb`
- `lib/solid_objects/database_adapters/sqlite.rb`
- `docs/database-schema.md`
- `test/models/schema_constraints_test.rb`
- `test/models/instance_test.rb`
- `test/models/message_test.rb`

### Public API

No new application API. Internal records are deliberately namespaced.

### Database changes

Create the seven domain tables plus ready- and claimed-message membership tables. Add foreign keys, unique constraints, positive sequence/version checks, ordinary composite polling indexes, and cleanup indexes. Use JSONB on PostgreSQL, JSON on MySQL, and Rails JSON-compatible columns on SQLite. Do not use partial indexes or a message status column.

### Tests

- Actor identity uniqueness
- Concurrent actor creation
- Counter and membership constraints
- Foreign-key cleanup behavior
- Ready and claimed hot-table index definitions
- Configured table prefix
- MySQL tables use InnoDB
- SQLite write transactions and busy retry

### Failure modes

- Unsupported database or server version
- Prefix changed after migration
- A message accidentally represented in both ready and claimed tables
- Cascades deleting required diagnostic data

### Completion criteria

The schema installs in PostgreSQL, MySQL, and SQLite dummy databases and database constraints reject invalid states independently of Rails validations.

## Milestone 3: Durable enqueue, references, tell, and ask

### Files

- `lib/solid_objects/reference.rb`
- `lib/solid_objects/client.rb`
- `lib/solid_objects/mailbox.rb`
- `lib/solid_objects/message_reference.rb`
- `lib/solid_objects/wake_up.rb`
- `test/integration/enqueue_test.rb`
- `test/integration/tell_test.rb`
- `test/integration/ask_test.rb`

### Public API

- `Reference#tell`
- `Reference#ask`
- Method-style message, query, and read-only attribute dispatch
- `MessageReference#id`, `#status`, `#result`
- Authorization context and hooks

### Database changes

No new tables. Use instance sequence and message request/idempotency columns.

### Tests

- Per-actor sequence allocation under concurrent connections
- Independent sequences for different actors
- Idempotency key deduplication
- Tell return value
- Ask success, failure, and timeout
- Mailbox and payload limits
- Message/query authorization failure

### Failure modes

- Concurrent first enqueue
- Lock timeout or deadlock
- Duplicate idempotency key with different payload
- Ask caller timeout
- Oversized payload or mailbox

### Completion criteria

Messages and ready membership enqueue durably in strict per-actor sequence and `ask` can observe a manually completed result. Polling-only `ask` is documented as unsuitable for latency-sensitive request handlers.

## Milestone 4: Fenced, runnable vertical slice

### Files

- `lib/solid_objects/activation.rb`
- `lib/solid_objects/lease.rb`
- `lib/solid_objects/executor.rb`
- `lib/solid_objects/worker.rb`
- `lib/solid_objects/dispatcher.rb`
- `lib/solid_objects/process_registry.rb`
- `examples/shopping_cart_actor.rb`
- `test/integration/vertical_slice_test.rb`
- `test/integration/sequential_processing_test.rb`
- `test/integration/retry_test.rb`
- `test/integration/lease_test.rb`
- `test/integration/fencing_test.rb`
- `test/integration/crash_recovery_test.rb`

### Public API

Runnable `SolidObjects::Worker`; current message context inside actors. A worker cannot process actor state without a registered process, renewable activation lease, and fencing generation.

### Database changes

No new tables.

### Tests

- Shopping cart tell and ask
- One actor processes messages sequentially
- Different actors can execute concurrently
- Lease acquire, renew, expire, and release
- Two workers cannot hold the same actor lease
- Deterministic stale-writer rejection
- Crash recovery and at-least-once redelivery
- State and completion are atomic
- Basic retry and strict head-of-mailbox blocking
- Handler-level duplicate-delivery guards
- Actor-to-actor tell outside actor context

### Failure modes

- Actor exception
- Serialization failure after actor code
- Query mutates state
- Worker shutdown during a turn
- Process pause beyond lease expiry
- Lease renewal race

### Completion criteria

The example actor runs end to end against all three databases and persists/reactivates state. Real multi-connection tests prove that generation A cannot write after generation B acquires and commits. The runnable worker always enforces leases and fencing; no unsafe single-worker mode exists.

## Milestone 5: Supervision, heartbeats, and distributed hardening

### Files

- `lib/solid_objects/supervisor.rb`
- `lib/solid_objects/activation_manager.rb`
- `lib/solid_objects/configuration.rb`
- `test/integration/process_lifecycle_test.rb`
- `test/integration/fairness_test.rb`

### Public API

Process configuration and lifecycle hooks.

### Database changes

Use process and activation columns already created. Add a migration only if query-plan evidence requires a new lease index.

### Tests

- Heartbeats and stale process cleanup
- Graceful shutdown
- Max message and duration budgets
- Hot actor fairness

### Failure modes

- Process pause rather than death
- Heartbeat task failure
- Database outage during release
- Child process boot or shutdown timeout

### Completion criteria

Real process tests on PostgreSQL, MySQL, and SQLite demonstrate heartbeat cleanup, bounded fairness, and graceful shutdown. PostgreSQL and MySQL additionally prove `SKIP LOCKED`; SQLite proves serialized `BEGIN IMMEDIATE` claims and busy retry.

## Milestone 6: Effects and actor-message outbox

### Files

- `lib/solid_objects/effect_registry.rb`
- `lib/solid_objects/effect_executor.rb`
- `lib/solid_objects/outbox_dispatcher.rb`
- `test/integration/effects_test.rb`
- `test/integration/actor_communication_test.rb`

### Public API

- `emit`
- `SolidObjects.register_effect`
- `send_to`

### Database changes

Use the effects table. Add delivery-token or outcome columns only through a migration.

### Tests

- Effect insert is atomic with state/message completion
- Rollback leaves no effect
- Delivery retry and dead effect
- Stable idempotency context
- Success/failure outcome messages
- Transactional actor-to-actor delivery
- `ask` rejected in actor context

### Failure modes

- External success before local acknowledgement
- Handler missing after deploy
- Outcome payload too large
- Target actor message renamed

### Completion criteria

Effects and actor messages are never delivered for a rolled-back actor turn and can be retried without losing their stable IDs.

## Milestone 7: Durable reminders

### Files

- `lib/solid_objects/reminder_scheduler.rb`
- `test/integration/reminders_test.rb`

### Public API

- `remind`
- Reminder cancellation and inspection API

### Database changes

Use reminders plus mailbox idempotency. Add a unique occurrence index if not in the initial schema.

### Tests

- One-shot reminder
- Recurring occurrence uniqueness with two schedulers
- Reminder reactivates idle actor
- Scheduler crash recovery
- Missed-occurrence policies
- Cancellation race

### Failure modes

- Clock jumps
- Duplicate scheduler claims
- Long outage creates excessive catch-up
- Reminder callback removed in code

### Completion criteria

Due reminders become ordinary mailbox messages exactly once per occurrence record while their eventual message execution remains at least once.

## Milestone 8: Realtime integration

### Files

- `app/channels/solid_objects/actor_channel.rb`
- `app/controllers/solid_objects/actor_states_controller.rb`
- `app/helpers/solid_objects/actors_helper.rb`
- `lib/solid_objects/stream_name.rb`
- `lib/solid_objects/broadcast_executor.rb`
- `config/routes.rb`
- `docs/realtime.md`
- `test/channels/solid_objects/actor_channel_test.rb`
- `test/helpers/solid_objects/actors_helper_test.rb`
- `test/integration/broadcasts_test.rb`

### Public API

- `actor_scope`
- Scope `value` and `component`
- Subscription and state-read authorization

### Database changes

Use broadcast outbox rows and their retry fields.

### Tests

- Initial server render
- Stable DOM IDs
- One actor subscription for multiple targets
- Signed token verification and authorization
- Changed observable detection
- Broadcast inserted with commit, never rollback
- Broadcast retry
- Reconnect refresh current state

### Failure modes

- Action Cable or Turbo absent
- Disconnected client
- Duplicate replacement
- Authorization changes while connected
- Component renderer missing

### Completion criteria

An authorized scope renders current values and converges after reconnect; observable broadcasts are durable and post-commit.

## Milestone 9: Operations, instrumentation, and dead letters

### Files

- `lib/solid_objects/cli.rb`
- `exe/solid_objects`
- `lib/solid_objects/log_subscriber.rb`
- `lib/solid_objects/instrumentation.rb`
- `lib/tasks/solid_objects_tasks.rake`
- `app/controllers/solid_objects/admin/**`
- `app/views/solid_objects/admin/**`
- `docs/operations.md`
- `docs/correctness.md`
- `docs/security.md`
- `test/unit/cli_test.rb`
- `test/integration/instrumentation_test.rb`
- `test/integration/dead_letters_test.rb`
- `test/models/instance_reconciliation_test.rb`

### Public API

CLI start, check, status, dead-letter list/retry, and prune commands. Optional read-only admin engine. Batchable read-only actor relations: `.active`, `.without_pending_work`, and `.orphaned`.

### Database changes

No expected changes.

### Tests

- Required notification events and redacted payloads
- Structured log fields
- Dead-letter inspection and retry
- Admin authorization
- Pruning retention and bounded batches
- CLI exit statuses
- Lost-alarm and orphan discovery without direct state mutation

### Failure modes

- Sensitive data in logs
- Unbounded admin queries
- Retrying wrong dead letter
- Cleanup racing with ask waiter
- Reconciliation code mutating actor state outside `tell`
- Reconciliation stampedes without delayed `available_at`

### Completion criteria

Operators can inspect health and failures without direct SQL, locate lost alarms and orphaned actors, and observe every required transition without raw arguments. Documentation requires reconciliation repairs to use delayed `tell` rather than direct instance updates.

## Milestone 10: Examples, benchmarks, documentation, and release hardening

### Files

- `test/dummy/app/actors/shopping_cart_actor.rb`
- `test/dummy/app/actors/chat_room_actor.rb`
- `test/dummy/app/controllers/**`
- `test/dummy/app/views/**`
- `benchmark/enqueue.rb`
- `benchmark/claim.rb`
- `benchmark/processing.rb`
- `benchmark/workloads.rb`
- `README.md`
- `docs/development.md`
- `docs/state-migrations.md`
- `docs/roadmap.md`

### Public API

Final documented v0.x API.

### Database changes

Only evidence-driven index changes, each with query-plan tests and migration notes.

### Tests

- Shopping cart and chat room end-to-end flows
- Per-backend query counts
- Rolling-version compatibility fixtures
- Full suite on supported Rails versions
- Standard Ruby and security audit
- Gem build and install smoke test

### Failure modes

- Example-specific API design
- Benchmark environment mistaken for capacity guarantee
- Version matrix regressions
- Packaging omits engine files or migrations

### Completion criteria

The gem builds, installs into the dummy app, passes all available database suites plus formatting, inline RBS, type, and security checks, and documents implemented, partial, and future behavior without a production-ready claim unsupported by evidence.
