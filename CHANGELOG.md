# Changelog

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
