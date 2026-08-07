# Changelog

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
