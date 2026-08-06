# Changelog

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
