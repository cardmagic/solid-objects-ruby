# Roadmap

## Implemented and tested

- Rails engine, install generator, migration, and CLI
- Explicit actor registry, references, JSON state, and state migrations
- Durable message history plus ready/claimed membership tables
- Concurrent sequence allocation and actor creation
- Activation leases, renewal, generations, and fenced commits
- Bounded activation passes, idle cache, hot-actor yield, and process records
- At-least-once retries, strict poison ordering, dead letters, and tail retry
- Transactional effects with success/failure actor messages
- Actor-to-actor asynchronous outbox delivery
- One-shot and recurring reminders with `:latest` or `:all` catch-up
- Durable observable broadcast outbox and authorized Action Cable refresh
- Reconciliation read APIs
- SQLite, PostgreSQL, and MySQL integration suites
- Inline RBS generation/validation, Steep, Standard Ruby, Solid Queue's exact
  RuboCop policy, and a warning-free Brakeman scan

## Partially implemented

- Supervisor: starts and drains thread roles, but does not replace a crashed
  role or run periodic maintenance automatically.
- Wake-up strategy: in-process signaling plus durable polling and injection are
  implemented; PostgreSQL `LISTEN/NOTIFY` and optional Redis adapters are not.
- Realtime: observable replacement and reconnect refresh are implemented;
  durable component replacement and Turbo append actions are not.
- Backpressure: mailbox/payload/state/result caps and fair yields exist;
  distributed per-actor rate limits and global admission control do not.
- Administration: actor and dead-letter views plus policy hooks exist; richer
  filtering, audit records, and bulk-safe tools do not.
- Outboxes use portable status rows with polling indexes; future versions may
  introduce narrow ready/claimed membership tables for very large outboxes.

## Next milestones

1. Add automatic supervisor role replacement and periodic dead-process cleanup.
2. Add PostgreSQL notification and optional Redis wake-up adapters with latency
   benchmarks and polling-race tests.
3. Add bounded retention/pruning commands and result lookup by request ID.
4. Add deadlock, lock-timeout, and SQLite-busy retry classification.
5. Add database/server-version checks and MySQL InnoDB verification at boot.
6. Add component broadcast rendering, Turbo append intents, and reconnect tests
   in a full browser.
7. Add distributed rate limits, global admission hooks, and cache-capacity
   eviction.
8. Expand security scanning and run compatibility CI across supported Rails and
   Ruby versions.
9. Benchmark all workloads under documented hardware/database settings.

No production-ready claim should be made until these hardening milestones have
operational soak evidence.
