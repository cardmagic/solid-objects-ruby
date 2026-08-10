# Changelog

## Unreleased

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
