# Changelog

## 0.5.1 - 2026-08-07

- Restore the SQLite busy wait that a synchronous invocation suspends for its
  deadline. Rails installs the busy wait as a Ruby busy handler through the
  sqlite3 `timeout` configuration, which `PRAGMA busy_timeout` reports as zero
  and silently replaces, so the previous save and restore left pooled
  connections with no busy handler at all. Every later writer on that
  connection, inside or outside Solid Objects, then failed immediately with
  `SQLite3::BusyException` instead of waiting for the lock.

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
