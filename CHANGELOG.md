# Changelog

## 0.14.5 - 2026-09-03

- Split broadcast claiming into separate pending and stale-processing probes,
  then choose the oldest locked candidate across both. The old `OR` query made
  MySQL, PostgreSQL, and SQLite collect and sort eligible rows before applying
  `LIMIT 1`; each probe now follows the existing
  `(status, available_at, id)` index while preserving delivery order, recovery,
  and concurrent claimant safety. No migration or new index is required.

## 0.14.4 - 2026-08-30

- Reuse the encoding the after image already built. `State#to_h` copies the
  state by encoding it and parsing the result, then threw the encoded string
  away, and `complete` normalized and encoded the same hash a second time to
  measure it. `to_h_with_byte_size` returns the copy with the size of the
  encoding that produced it, so a committed turn now traverses the state twice
  rather than three times and encodes it twice rather than three times.
  Measured on SQLite against 0.14.3, committed throughput rises 5.3% at 13 KB
  of state, 16.1% at 116 KB, and 12.0% at 1 MB. `docs/benchmarks.md` holds the
  numbers. `solid-objects-js` already measured the string it commits; this
  brings the gem to the same shape.
- Add `Serialization.deep_copy_with_byte_size`, which returns a deep copy
  beside the size of its encoded form. `deep_copy` now calls it, so both
  encode once.
- Enforce `max_state_bytes` against the size the after image reports rather
  than by encoding the state again. The turn still fails with
  `PayloadTooLarge` before it opens its commit transaction, which a test now
  covers end to end.

## 0.14.3 - 2026-08-29

- Cut one of the three full state copies a committed turn made. The executor
  built the after image twice, once to answer whether the state changed and
  once for the committed row, and a synchronous query built a third for the
  mutation guard. One image now answers all three. Measured on SQLite,
  committed throughput rises 4.8% at 13 KB of state, 3.1% at 116 KB, and 10.2%
  at 1 MB. `benchmark/state_size.rb` is the scenario and `docs/benchmarks.md`
  holds the numbers. The guard now compares the image taken after the
  observables are read, so a query whose observable mutates state also fails
  with `InvalidActor`.
- Stop building an encoded string that `Serialization.dump` discarded. The
  method encoded every value to measure it, while most call sites pass no
  `max_bytes`. It now encodes only when a limit applies. That encoding was also
  the only check that a string held valid bytes, so `normalize` now checks the
  encoding of every string and key it visits. A value it rejects raises
  `InvalidPayload` at the call that staged it, as before, rather than a
  `JSON::GeneratorError` from inside the commit transaction.
- Add `warn_state_bytes`, a soft threshold that defaults to 64 KB and must not
  exceed `max_state_bytes`. A commit above it reports
  `solid_objects.state.large` with the actor identity, the `byte_count`, and
  the threshold. The event carries no application state, and it reports after
  the commit. `max_state_bytes` keeps its 5 MB default, which measurement shows
  is a limit rather than an operating point. The setting, the event, and its
  payload match `warnStateBytes` in solid-objects-js, which defaults to 128 KB,
  because the Node curve falls later than this one.
- Report a committed turn without letting a subscriber fail it. Every event
  the executor emitted after its commit ran outside a rescue, so a subscriber
  that raised turned a committed turn into a failed one: the runtime skipped
  `message.completed`, tried to fail a message whose claim it had already
  destroyed, and lost the worker pass. Those reports now go through
  `instrument_after_commit`, which reports a raising subscriber as
  `solid_objects.instrumentation.failed` and continues. This matches the
  isolation `solid-objects-js` already applied to every event it emits.

- Align the use-case claims with solid-objects-js. "Is it worth installing
  here?" listed long-lived workflows without a limit, while `docs/fit.md`
  called a rate limiter an anti-pattern and the JS README sold per-key rate
  limits. Both projects now say the same thing: a low-rate quota that a
  reminder refills fits, because each check is one durable ordered message; a
  limiter that every request touches does not; and a workflow fits when one
  entity owns the mutable state and its mailbox holds the step order. A durable
  execution engine that replays named steps from a step log remains a different
  tool.
- Name Solid Objects Pro in `docs/fit.md` for the high-QPS cases the guide
  rejects, and map its three capabilities onto them: grouped operations,
  ephemeral operations, and reactive projections. The README already pointed
  there; the fit guide stopped at "anti-pattern".
- Title the README "Solid Objects Ruby", matching "Solid Objects JS" in the
  Node package, and give both the same two badges. The CI badge now pins
  `?branch=main`, and a RubyGems version badge sits beside it. The gem name,
  the module, and the published metadata do not change.

## 0.14.2 - 2026-08-25

- Rewrite the first screen around the objection a reader actually has. The
  README led with a counter incrementing an integer, which invites the reply
  that one line of SQL already does it. It now leads with the ticket sale from
  the homepage: 100 seats, a hold, a ten-minute expiry that frees the seat, and
  a live count. That is the smallest example needing three things from one
  number, and the three things are the argument.
- Answer "why not just use transactions?" in the first screen rather than at
  line 1245 of a 1370-line file. The section concedes `with_lock` first, then
  argues scope rather than discipline: any `expires_at` or `scheduled_at`
  column is evidence the critical section already outlived the lock, and what
  follows it is a sweeper and a race. The comparisons table gains the row
  people actually reach for.
- Add "Is it worth installing here?", which names who should not install this,
  and point readers with high-QPS reads or hot identities at
  [Solid Objects Pro](https://solidobjects.pro/).
- Fix the reactive example, which could not run. A scalar observable raises
  unless it is declared `broadcast: :value`, and a component dependency must
  itself be a declared observable. The example now declares both. The reactive
  section also claimed a fragment is re-rendered once per change; the turn
  records the broadcast atomically, while delivery retries and is at least
  once.
- Cut the README from 1370 to about 580 lines by moving reference material into
  `docs/`, and add `CONTRIBUTING.md`. Reminders now have their own guide at
  `docs/reminders.md`, `docs/operations.md` gains the configuration defaults
  table, the worker-count flags, the upgrade sequence and the extension
  component contract, and `docs/architecture.md` gains `register_effect` and
  `register_commit_action` with their signatures.

## 0.14.1 - 2026-08-24

- Register application actors in every process that boots the application.
  The engine now loads the host application's `app/actors` directories from a
  `to_prepare` hook, which previously only the `solid_objects start` process
  did. An actor registers itself as a side effect of its class loading, so a
  lazily loading web process began with an empty registry. `ActorChannel`
  looks the actor up by name, and the resulting `UnknownActorType` reached the
  rescue that rejects the subscription: a Cable subscription for a real actor
  was rejected in any web process that had not yet rendered that actor, and
  the page kept a card that never updated. `ComponentsController` resolves the
  same way through `ActorSnapshot`. `Transmission.receive` already carried a
  registry-miss retry for this reason, and it stays as a guard for a host that
  reaches the gem without the engine.
- Report why a Cable subscription was rejected. Every reject path in
  `ActorChannel#subscribed` now emits `solid_objects.subscription.rejected`
  with a `reason`, the actor identity, and the `error_class` where an
  exception caused it. Five conditions previously collapsed into one silent
  `reject`, which is invisible from the browser and left nothing in the log to
  distinguish an unregistered actor type from a tampered token. Exception
  messages stay out of the payload, because a component or payload failure can
  carry actor state.

- State where `async` waits when no worker runs. The `async` section of the
  README and the runtime section of `docs/operations.md` now say that the
  generator and the migrations start no role, so an application that serves
  web requests alone leaves the message ready until
  `bundle exec solid_objects start` runs the roles. The message is durable
  and waits; it is not lost. `test/integration/background_pickup_test.rb`
  pins it: the message reads `ready` and the actor state stays empty until a
  worker runs. This matches solid-objects-js#22, which reported the same gap
  for `runtime.run(signal)` in the Node package.

- Add `examples/at_least_once` and `bundle exec rake at_least_once`, an
  executable proof that the at-least-once clause fires and that the
  documented remedy absorbs it. One actor turn stages an effect that writes
  to an external sink file. The first effect worker crashes between the sink
  write and the acknowledgement, and a second worker reclaims the stale
  effect after the liveness threshold and delivers again. With deduplication
  off the sink reads 2, both deliveries carrying the same `context.id` at
  attempts 1 and 2; with a guard on that id the sink reads 1. The actor state
  commits exactly once in both runs. CI runs the demo in the SQLite job, and
  `docs/correctness.md` links it from the handler idempotency section. This
  mirrors `pnpm run test:at-least-once` in solid-objects-js.

## 0.14.0 - 2026-08-22

- Add `SolidObjects::Transmission.receive(envelope)`, the server ingest for
  the browser transmit family in solid-objects-js. It validates a camelCase
  transmit envelope, resolves the actor type through an optional
  `resolve_actor_type:` proc, and enqueues one internal message with the
  idempotency key `transmit:<effectId>`, so a replayed envelope applies
  once. Malformed envelopes raise the new
  `SolidObjects::InvalidTransmission`. Internal delivery skips
  `authorize_message`, so the host application must authenticate the
  request before it calls `receive`; see `docs/transmission.md` for the
  controller boundary. On a registry miss under Rails, `receive` loads the
  application's actor classes once and retries, because a lazy-loading web
  process has no other reason to have loaded the target class. Golden
  fixtures in `compatibility/transmit-envelopes.json` pin the wire contract
  shared with the JS runtime.
- Add `Actor#transmit` and `SolidObjects.register_transmit`, the staging
  side of the transmit family. `transmit.increment(amount:)` stages a
  `solid-objects.transmit` effect in the same commit as the state change;
  `register_transmit` drains staged effects into camelCase envelopes and
  hands each to the delivery block, which raises to retry. A claimed
  transmit effect delivers every undelivered sibling for its actor up to
  its own mailbox sequence, oldest first, so per-actor order survives a
  failed delivery, and the receiving side dedups on `transmit:<effectId>`.
  A raw `emit "solid-objects.transmit"` with explicit `actorType` and
  `actorId` targets a different actor, matching the JS staging surface.
- Mount `POST /solid_objects/transmit` in the engine, an ingest route
  behind the new deny-by-default `authorize_transmission` policy. The
  policy receives the parsed envelope and the controller, an unauthorized
  envelope gets 403, and a permanently unappliable one gets 422, so a
  sending outbox dead-letters it instead of retrying forever. The new
  `transmission_actor_type_resolver` configuration maps diverged actor
  type names for the engine route.

## 0.13.3 - 2026-08-18

- Stop loading `ActiveRecord::Base` when the gem is required. The engine now
  loads `SolidObjects::Record` from an `ActiveSupport.on_load(:active_record)`
  hook, so a host application keeps the normal timing of its own
  `on_load(:active_record)` and `on_load(:active_record_encryption)` hooks. An
  application that assigns its Active Record encryption keys in
  `config/initializers` no longer loses them.
- Apply the configured `connects_to` in the record class body, so the
  connection follows the class through a development reload.
- Lower the supported Rails floor from 8.0 to 7.1. The gem dependencies, the
  bundled migrations, and the compatibility CI matrix now cover Rails 7.1, 7.2,
  8.0, and 8.1. The migrations declare `ActiveRecord::Migration[7.1]`, which
  builds the same schema as `[8.0]` because the compatibility layer between the
  two only changes `remove_foreign_key`, which no Solid Objects migration calls.
  Rails 7.0 stays out of range: its SQLite adapter requires `sqlite3 ~> 1.4`,
  and the busy-handler control this gem needs arrived in `sqlite3` 2.x.

## 0.13.2 - 2026-08-17

- Accept a `key:` on `schedule`, naming a reminder for the item it is waiting
  on rather than for its operation, so one actor can hold an alarm per queued
  item. Scheduling the same key again moves that item's alarm and leaves the
  others alone. Without a key the name is still the operation, so existing
  reminders keep their names and their coalescing behaviour. A reminder
  operation may no longer hold the colon that separates a key, which keeps
  keyed and unkeyed names disjoint, and the length is checked on the composed
  name rather than the key alone.
- Add an authorized `SolidObjects.administration.processes` query for
  inspecting live and stale process rows through the runtime database adapter.
- Document rolling-deployment overlap as a reason for the polling-only warning.

## 0.13.1 - 2026-08-16

- Back idle actor, effect, reminder, and broadcast polling off exponentially
  from the configured fast interval to a new one-second idle ceiling. Any
  processed work or wake-up resets the role immediately, and actor polling
  remains capped by the lease-renewal interval.
- Expose each role's `current_polling_interval` and emit
  `solid_objects.polling.interval_changed` instrumentation for every idle,
  work, and wake-up transition.
- Warn once when live processes share the database without a configured
  cross-process wake-up adapter.
- Make the in-process wake-up generation-aware so a signal committed between
  an empty claim and the wait is not missed. PostgreSQL and Redis adapters now
  expose the same watch contract.
- Add a reproducible four-role SQLite idle benchmark and repair the benchmark
  schema setup for the current operation columns.
- **Behavior change:** `polling_interval` is now the fast interval after
  activity, not a constant idle cadence. Existing explicit values back off to
  `idle_polling_interval`, which defaults to one second. Set both options to
  the same value to preserve a fixed cadence. Existing custom wake-up adapters
  that return `nil` remain at the fast cadence until they return `false` for a
  timeout and `true` for a notification.

## 0.13.0 - 2026-08-15

- **Breaking:** make observables invalidation-only by default. An ordinary
  `observable :status` continues to detect changes and refresh reactive
  components, but persists `{}` and sends no scalar value over Action Cable.
  Declare `observable :status, broadcast: :value` to deliberately store and
  share the projection with every authorized actor subscriber. Applications
  upgrading from 0.12.x must add that opt-in to observables rendered as scalar
  targets.
- Add `SolidObjects::Web`, a mountable Rack dashboard for the actor runtime.
  It covers instances and their committed state, the ready and claimed
  mailbox, reminders, effects, broadcasts, dead letters, and processes, with
  actor-type and actor-id filtering, status filters, paging, and a polled
  `GET /stats` endpoint. Mount it with
  `mount SolidObjects::Web => "/solid_objects/dashboard"` after
  `require "solid_objects/web"`; requiring the gem does not load it, so a
  worker process carries no web stack.
- Authorize every dashboard route through `authorize_administration`. Each
  route declares its own `action` and `resource`, and a route declared without
  a policy raises at load time. The policy receives a context that answers
  `request`, `session`, and `env`.
- Add two dashboard actions: an idempotent dead letter retry through
  `SolidObjects.dead_letters.retry`, and instance pause/resume, which sets and
  clears `paused_at` so the activation manager stops claiming that identity. A
  retry the mailbox refuses, such as an actor class that no longer exists,
  renders the reason with a 422 rather than failing the request.
- Draw instances per actor type, mailbox depth, and outbox and reminder status
  with Chart.js, loaded from a CDN with a subresource integrity hash. The CDN
  host is the only external origin the content security policy names. Point
  `SolidObjects::Web.chart_library_url` at a vendored copy for a deployment
  with no outbound network access, or set it to nil to render without charts.
- Add `SolidObjects::Web.register` for extension tabs, routes, and view
  directories, and `SolidObjects::Web.use` for Rack middleware in front of the
  dashboard.
- Add `rack` as an explicit dependency at `>= 3.1`, and package the `web/`
  directory in the gem.

## 0.12.1 - 2026-08-13

- Add invalidation-only observables with `broadcast: :invalidation`. They still
  detect changes and refresh reactive components, but persist `{}` and send no
  scalar value over Action Cable. Document that ordinary observable values are
  shared with every authorized actor subscriber and that subscriber-specific
  state belongs in a payload projection.
- **Breaking:** include the originally staged `arguments:` in effect success
  and failure callbacks so actors can correlate concurrent effects.
- Accept identifier-style rejection codes, including camelCase and symbols,
  and fail malformed codes once with non-retryable
  `SolidObjects::InvalidRejectionCode` diagnostics.
- Add `run_due_reminders(now:)` to `SolidObjects::TestHelper` for deterministic
  reminder tests without sleeping or mutating runtime rows.

## 0.12.0 - 2026-08-13

- Replace positional actor dispatch with fluent operation selection. Direct
  committed calls remain `account.disable(...)`; configured committed calls
  use `account.sync(timeout: ...).status`; asynchronous calls use
  `account.async(...).disable(...)`; actor outbox delivery uses
  `send_to(account, ...).disable(...)`; and reminders use
  `schedule(at: ...).evaluate(...)`. Delivery and reminder options are now
  unambiguously separate from actor message arguments. The former positional
  `async`, `sync`, `send_to`, and `schedule` forms are removed.
- Validate fluent operations before enqueueing or staging them. Direct and
  configured synchronous calls accept messages and queries, while `async`,
  `send_to`, and `schedule` accept public actor messages only.
- Use operation terminology throughout invocation persistence and diagnostics.
  The new migration renames stored message names to `operation`, message kind
  to `delivery_mode`, and effect callback message names to operation names.
- Make internal methods with more than two arguments keyword-only so dispatch,
  persistence, component refresh, and diagnostics call sites name every value.
- Keep SQLite reconnect failures inside a synchronous lock deadline. Active
  Record can reconnect after a lock error while the lock is still held, and
  configuring WAL then raises `SQLite3::CantOpenException`; it now retries
  within the original deadline and surfaces the documented sync timeout.

## 0.11.0 - 2026-08-11

- Add `SolidObjects.configuration.register_component`. An extension gem can now
  register a long running component, and the supervisor runs it beside the
  workers, the effect executors, the broadcast executors, and the reminder
  schedulers. The component joins the same supervision, replacement, and
  shutdown timeout. Without it, an extension has to ask an operator to run and
  monitor a second process for work that belongs to the same runtime. A
  registered component must answer `run`, `request_shutdown`, `stopped?`, and
  `stop`. The supervisor checks that contract when it builds the component and
  raises `ArgumentError` when a method is missing. Registration never calls the
  block, so a component may need a database connection that the application
  does not have while it boots.

- Stop the components already built when a later one fails. The supervisor
  builds its components one after another, so a factory that raised, or a
  component that failed the contract check, left the earlier ones constructed
  and unreachable while they still held whatever their constructors took. Each
  one now receives `stop`, and a failure inside that cleanup never replaces the
  failure that caused it.

- Replace a crashed component through the builder that made it. The supervisor
  called `component.class.new`, which discards every constructor argument, so a
  component built with arguments returned with its defaults after a crash. Each
  component now keeps its builder. The built in components take no constructor
  arguments, so their behavior does not change.

## 0.10.3 - 2026-08-11

- Delete every actor-owned row in `SolidObjects::TestHelper#reset_actors!`. It
  deleted actor instances and processes and left the other seven tables to the
  database cascade. That cascade is not enforced everywhere: SQLite has to be
  asked for foreign keys, MySQL has to be on InnoDB, and a host application may
  have stripped the constraints out of the copied migration. Where it does not
  fire, messages, ready and claimed mailbox rows, reminders, effects,
  broadcasts, and dead letters all survived into the next test with an
  `instance_id` pointing at nothing, so a test reading any of them saw another
  test's rows and failed depending on order. Reported as reminders leaking,
  which is where it surfaces first because reminders outlive the message that
  created them.
- Document that a reminder is one named alarm per actor. `schedule` is keyed by
  actor and reminder name, so scheduling a name that is already armed moves
  that alarm rather than adding a second. The behaviour is deliberate and
  matches Orleans and Durable Objects, but it was stated nowhere: an actor that
  armed one reminder per queued item silently kept only the last, and the
  earlier wake-ups never happened. The reminders guide now states the
  uniqueness key and shows the one-alarm-many-items pattern to use instead.
- Add `solid_objects.reminder.replaced`, reported when a `schedule` call moves
  an alarm already armed under the same name to a different time. It carries
  the actor identity, reminder name, previous run time, and next run time, and
  no arguments. Rescheduling to the same time reports nothing. The replacement
  was previously indistinguishable from a first schedule.

## 0.10.2 - 2026-08-10

- Load the mailbox when the gem is required. `SolidObjects::Mailbox` was
  reachable only through the caller path, which loads it as a side effect of
  `SolidObjects.client`. The reminder scheduler and the effect executor enqueue
  through it directly and run in `solid_objects start`, a process that never
  calls the client, so both raised
  `NameError: uninitialized constant SolidObjects::ReminderScheduler::Mailbox`.
  Reminders never fired and effect result messages never delivered, while the
  supervisor replaced the dying role over and over. Nothing caught it because
  every test process has already loaded the constant through some other path.
- Add a load contract test that asks a fresh process what `require
  "solid_objects"` actually defines, and fails when a file stops being loaded
  unless it is listed as deliberately deferred with a reason. This is the class
  of bug that only appears in the standalone worker.
- Run a due reminder through a real `solid_objects start` worker in the test
  suite, rather than only in process.

## 0.10.1 - 2026-08-10

- Support Trilogy. Adapter selection matched the client name rather than the
  protocol, and Trilogy reports `"Trilogy"`, so every Solid Objects call raised
  `UnsupportedDatabase: unsupported database adapter "Trilogy"` on a database
  the gem fully supports. Adapter names now resolve through one table of
  families, `DatabaseAdapter.family`, used by adapter selection, owner-id
  casting, and wake-up adapter selection alike, so a client cannot be accepted
  in one place and rejected in another.
- Compare reconciliation owner ids in the column's own collation.
  `Instance.orphaned` cast owner primary keys to `CHAR`, and a cast result
  carries the connection collation rather than the column's. MySQL refuses to
  compare two collations, so the query raised `Illegal mix of collations`
  whenever the two differed. That is a property of the client rather than the
  schema: mysql2 negotiates the database default while Trilogy negotiates
  `utf8mb4_general_ci`. A mysql2 application that set `collation:` in
  `database.yml` could already hit this.
- Recognise a statement interruption from any MySQL client. A synchronous
  deadline is enforced by asking the server to interrupt the statement, and the
  interruption was matched only through mysql2's `error_number`. Trilogy names
  it `error_code`, so a deadline surfaced as a raw
  `ActiveRecord::StatementTimeout` instead of `SyncEnqueueTimeout`. Both names
  are read, and Active Record's own classification is trusted first.
- Run the MySQL suite against both mysql2 and Trilogy in CI, and key
  adapter-specific test skips to the database family rather than the client
  name, so a Trilogy run no longer silently skips every MySQL test.

## 0.10.0 - 2026-08-10

- Report a denied CLI command as a policy decision rather than a crash.
  Administration denies by default, so an unconfigured host met a thirty-line
  Ruby backtrace on its first `solid_objects` command. The executable now
  prints the refusal and the setting that grants access, and exits 1.
- Measure the query count for a synchronous call. `benchmark/query_count.rb`
  only measured a worker turn, so the documented synchronous number had no
  script behind it. It reports three now: a message turn costs 26 queries
  rather than the documented 29, the caller of a synchronous call costs 49, and
  a synchronous call in total costs 75, being a caller plus the turn it waits
  on. Counting is scoped to the measuring thread, since a worker loop polls
  whether or not a call is in flight and a process-wide count folds those polls
  into the result.

- Run payload broadcast blocks against the actor instance, like every other
  block in the actor DSL. `self` was the actor class, so an actor instance
  method called from a payload block raised
  `NoMethodError: undefined method 'x' for class PlaymatRoom`. Blocks keep
  receiving the actor and the authorization context as arguments, so the
  documented signature is unaffected. A block that relied on the class receiver
  now raises `InvalidPayloadBroadcast` naming the method and the change instead
  of an unexplained `NameError`.
- Add `payload_authorization_context`, the payload counterpart to
  `component_authorization_context`. Payloads are computed inside the channel,
  so without a resolver the payload block and its `authorize_query` call
  received the raw Action Cable connection while a controller render passed an
  application object, and the authorization hook had to tell them apart. The
  resolver may also accept `payload_name:`. It defaults to returning the
  connection unchanged.
- Confine a failing payload to itself. A raising payload block propagated out of
  the channel: on subscribe it rejected the subscription, and on a broadcast it
  abandoned the remaining payload names, which showed up in the browser only as
  reactive updates that stopped arriving. A failure is now reported as
  `solid_objects.payload_broadcast_failed` with the actor type, actor id,
  payload name, and exception class, and delivery continues. The exception
  message is deliberately excluded so subscriber state cannot leak into logs. A
  revision with a failed payload does not advance the delivery watermark, so a
  transient failure is retried on the next broadcast instead of being recorded
  as delivered and deduplicated away.
- Run retention on the supervisor rather than leaving it configured but
  unscheduled. Every actor call writes a durable message row, so a policy that
  nothing invokes let history grow without bound until an application scheduled
  its own job. `retention_interval` defaults to one hour, and zero disables it.
  Retention runs on its own thread, so a slow pass cannot delay replacing a
  crashed role, and a failed pass retries at monitor cadence with a doubling
  backoff rather than deferring for the whole interval.
- Batch component refreshes on reconnect. A reconnecting subscription refreshed
  every stale component individually, ignoring the batches those components
  declared, so a page with twenty batched components issued twenty requests
  instead of one. That happens at the worst moment: a server restart reconnects
  every client at once. Reconnect now shares the batching the live invalidation
  path uses.
- Cover the reconnect burst in the browser suite: convergence of batched and
  unbatched components, an inert replay of an already-applied revision,
  cancellation of the request left in flight by the drop, incarnation ordering
  after a destroy and recreate, and payload delivery exactly once per revision.
- Add Ruby 4.0 to the compatibility matrix, which now covers Ruby 3.3, 3.4, and
  4.0 against Rails 8.0 and 8.1.

## 0.9.0 - 2026-08-10

- Add a browser test suite running the refresh modules against real Chromium and
  a real Turbo build, covering `component_refresh.js`, which previously had no
  tests at all. Every batching defect that reached production passed the jsdom
  suite, because jsdom cannot model Turbo applying a morph, task boundaries
  between socket deliveries, or abort semantics.
- Verify the database server. Each adapter reports its version against the
  oldest one Solid Objects is exercised against, PostgreSQL 13, MySQL 8.0, and
  SQLite 3.35, and MySQL additionally confirms that Solid Objects tables use
  InnoDB, since a non-transactional engine would silently break fenced commits.
  The doctor reports this as `database_server` and warns rather than failing:
  refusing to run on an untested server would be a worse failure than running
  on one.
- Add `SolidObjects::WakeUpAdapters::Redis`, an optional cross-process wake-up
  using Redis publish and subscribe. This is the option for MySQL, which has no
  notification primitive. Measured cross-process wake-up latency drops from
  103.8 ms to 5.7 ms at p50. One background subscription per process fans out to
  every waiting role in memory. The `redis` gem is not a dependency of this gem,
  and `WakeUpAdapters.for` does not select it, so adopting Redis stays explicit.

## 0.8.0 - 2026-08-10

- Replace a supervised role whose thread died. A role that raised left its
  thread dead while the process kept running and quietly did less work; the
  supervisor now restarts it until shutdown is requested. Prune dead process
  records on an interval as part of the same monitor. Both intervals are
  configurable through `supervisor_monitor_interval` and
  `dead_process_cleanup_interval`.
- Run compatibility CI across the span the gemspec advertises: Ruby 3.3 and 3.4
  against Rails 8.0 and 8.1. The suite previously ran on one combination, so
  `>= 8.0` was a claim rather than a tested guarantee. Set `RAILS_VERSION` to
  pin a Rails line locally.
- Stop a synchronous lock retry from asking for a negative wait when its
  deadline expires between the check and the wait, which raised
  `ArgumentError: time interval must not be negative` instead of the timeout
  the caller expected. Found by the new compatibility matrix.
- Add `SolidObjects::WakeUpAdapters::Postgresql`, an optional cross-process
  wake-up using PostgreSQL notifications. In-process signalling cannot reach a
  worker process, so reactive delivery waited out `polling_interval`. With the
  adapter configured, measured cross-process wake-up latency drops from 103.7 ms
  to 2.9 ms at p50. The polling interval remains the upper bound, and neither
  signalling nor waiting raises into its caller. `WakeUpAdapters.for` selects
  notifications on PostgreSQL and the in-process default elsewhere; it is not
  the default, because the adapter opens a connection per waiting thread
  outside the pool and `LISTEN` does not survive a transaction-pooling proxy.

## 0.7.3 - 2026-08-09

- Coordinate batched component refreshes by revision as well as scope and batch
  name. Invalidations for one revision arrive as separate WebSocket messages, so
  the microtask merge could not see them all, and each request aborted the one
  before it. Only the last component updated. Same-revision requests now run
  alongside each other and every frame is applied; only a strictly newer
  revision supersedes an in-flight request. Frames already applied at a revision
  are not applied twice.

## 0.7.2 - 2026-08-09

- Render batched component partials as HTML regardless of the request format.
  The batch endpoint is requested with a JSON `Accept` header, so Rails looked
  for JSON templates, raised `ActionView::MissingTemplate`, and the batch
  returned 404 for applications whose components are ordinary
  `.html.erb` partials. The outer response is still JSON. Single-component
  refresh was never affected and is unchanged.
- Pass `registrations:` to `component_authorization_context`: one registration
  for a single refresh, all of them for a batch, so applications no longer have
  to inspect `params[:tokens]`. Callbacks accepting only `controller:` keep
  working unchanged.

## 0.7.1 - 2026-08-09

- Retry a contended SQLite write outside a synchronous deadline. Asynchronous
  enqueue had no Ruby-level retry budget, so it depended entirely on SQLite's
  busy handler and raised `SQLite3::BusyException` once concurrent writers
  exhausted it. Bounded by the new `lock_retry_attempts` setting.
- Pin every GitHub Actions reference to a commit SHA.
- Add a benchmark comparing individual, batched, and payload delivery for one
  mutation that changes three components.

## 0.7.0 - 2026-08-09

- Add `batch:` to reactive components. Components sharing a batch in one actor
  scope collapse into a single browser request per revision instead of one
  request per component. The new `GET /solid_objects/components/batch` endpoint
  returns HTML frames inside a documented JSON envelope, so Turbo morph and ERB
  rendering are unchanged while the contract stays machine readable. Duplicate
  notifications for the same batch and revision coalesce in the browser,
  unchanged components are never requested, and stale frames cannot overwrite a
  newer target. Components without `batch:` behave exactly as before.
- Add a JavaScript test suite for the browser modules, run in CI with Node's
  test runner and jsdom.

## 0.6.0 - 2026-08-09

- Add `broadcast_payload`, an actor DSL for sending one personalized JSON state
  payload over the actor stream a page already has open. The block runs once per
  subscriber with that subscriber's authorization context, so private state
  never crosses sessions. Payloads carry actor identity and the monotonic state
  revision, and both the channel and the browser drop stale revisions. Subscribe
  with `solid_object room, payloads: :playmat_state` and handle the
  `solid-objects:payload` DOM event. ERB component refreshes remain the default
  and are unchanged. A mutation that changes payload state without changing a
  declared observable still invalidates subscribers, through a revision-only
  broadcast that carries no observable value to the browser.

## 0.5.2 - 2026-08-09

- Read the database clock once per transaction instead of once per step, and
  resolve the SQLite busy wait from configuration instead of querying the
  connection for it. A synchronous call now issues 49 database queries instead
  of 66, which matters most on PostgreSQL and MySQL where every query is a
  network round trip.
- Apply every migration in the benchmark harness. It applied only the initial
  migration, so the `state_revision` column added in 0.4.0 was missing, every
  message failed at commit, and the synchronous benchmarks timed out.

## 0.5.1 - 2026-08-07

- Restore the SQLite busy wait that a synchronous invocation suspends for its
  deadline. Rails installs the busy wait as a Ruby busy handler through the
  sqlite3 `timeout` configuration, which `PRAGMA busy_timeout` reports as zero
  and silently replaces, so the previous save and restore left pooled
  connections with no busy handler at all. Every later writer on that
  connection, inside or outside Solid Objects, then failed immediately with
  `SQLite3::BusyException` instead of waiting for the lock. Suspend the busy
  wait only when the adapter can identify how to restore it, so an Active
  Record release that stops exposing the configured timeout loosens
  synchronous deadline bounds instead of stripping lock waiting from a shared
  pooled connection.

- Run the doctor round-trip probe on a dedicated caller process, and accept an
  explicit process registry in `SynchronousInvocation`, so the probe can no
  longer stop and delete a shared application caller process, release its
  activations, and unclaim its messages.
- Report doctor probe cleanup failures as a failed or warned check instead of
  raising a database lock error out of the command and leaking the probe
  caller process.
- Instrument component refreshes with actor identity, component name, key,
  dependencies, refresh method, revision, and outcome, excluding locals.

## 0.5.0 - 2026-08-07

- Add repeatable reactive components with signed string or integer keys and
  JSON-compatible partial locals.
- Add opt-in Turbo morph refreshes with superseded-request cancellation and
  browser-side actor revision fencing.
- Pass signed component keys and locals through request-time query
  authorization without broadcasting personalized HTML.

## 0.4.3 - 2026-08-07

- Bound SQLite caller-process registration, reuse, heartbeat, and synchronous
  result observation retries by the original invocation deadline.
- Load host application actors from `app/actors` before CLI workers start,
  including development environments with eager loading disabled.

## 0.4.2 - 2026-08-07

- Decode Action Cable broadcast payloads before parsing observable invalidations
  so scalar updates and component refreshes transmit as raw Turbo Stream HTML.

## 0.4.1 - 2026-08-07

- Load `SolidObjects::ActorChannel` with the gem and pass stream and component
  subscription tokens through Turbo-compatible `data-*` attributes.

## 0.4.0 - 2026-08-06

- Add dependency-driven live ERB components with request-time authorization,
  conventional partial resolution, revision fencing, refresh coalescing, and
  reconnect convergence without broadcasting personalized HTML.
- Persist a monotonic state revision for secure component refresh ordering.
- Retry SQLite synchronous lock contention in Ruby so a native busy wait
  cannot starve the thread holding the database lock.
- Allow maintainers to dispatch CI manually when a push webhook is dropped.

## 0.3.0 - 2026-08-06

- Reject application-record writes from actor handlers and provide registered
  same-database commit actions for fenced atomic changes.
- Reject synchronous invocation inside an open Solid Objects transaction and
  add adapter database deadlines, durable diagnostics, and recoverable results
  to sync timeouts.
- Guard handlers, observables, lifecycle hooks, and state migrations from
  direct application-record writes.
- Add dry-run-first bounded message, process, and opt-in actor-instance
  pruning, configurable retention, and graceful caller-process shutdown.
- Add authorized committed state snapshots, mutable JSON copies, commit-action
  instrumentation, and deterministic full-runtime Minitest draining.

## 0.2.1 - 2026-08-06

- Add `solid_objects:doctor` for configuration, schema, policy, runtime, and
  workerless synchronous round-trip verification.
- Add onboarding guidance for fit decisions, worker requirements,
  authorization, performance and row growth, retention, Sorbet, RuboCop, and
  migrations from existing state stores.
- Make the early-Action View engine boot regression explicit.

## 0.2.0 - 2026-08-06

- Make direct actor methods synchronous Durable Object-style RPC.
- Add explicit `sync` and `async` invocation modes.
- Let synchronous callers assist execution through the ordered mailbox using
  the same activation leases and fencing checks as workers.
- Add terminal domain rejections that roll back actor state without retrying or
  creating dead letters.
- Give each activation a unique token so concurrent callers in one process
  cannot share lease ownership.
- Fix Action View helper loading when Action View initializes before engine
  autoload paths.

## 0.1.0 - 2026-08-06

- Introduce the Rails engine, actor API, and `solid_objects` executable.
- Register public actor methods as durable messages and add method-style
  reference calls, ordered attribute reads, actor attribute accessors, and
  observable view helpers.
- Add ordered durable mailboxes with ready and claimed membership tables.
- Add renewable activation leases with monotonically increasing fencing
  generations.
- Add JSON actor state, versioned migrations, retries, and dead letters.
- Add transactional effects, actor-to-actor messages, and durable reminders.
- Add observable Turbo replacements through a durable broadcast outbox.
- Add authorized, fenced actor destruction with cascading mailbox, reminder,
  effect, broadcast, and dead-letter cleanup.
- Support SQLite, PostgreSQL, and MySQL.
