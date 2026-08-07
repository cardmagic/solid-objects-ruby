# Roadmap

## Implemented and tested

- Rails engine, install generator, migration, and CLI
- Explicit actor registry, references, JSON state, and state migrations
- Direct synchronous RPC, explicit `sync`, and durable `async`
- Durable message history plus ready/claimed membership tables
- Concurrent sequence allocation and actor creation
- Activation leases, renewal, unique activation tokens, generations, and
  fenced commits
- Bounded activation passes, idle cache, hot-actor yield, and process records
- At-least-once retries, terminal domain rejection, strict poison ordering,
  dead letters, and tail retry
- Transactional effects with success/failure actor messages
- Actor-to-actor asynchronous outbox delivery
- One-shot and recurring reminders with `:latest` or `:all` catch-up
- Durable observable invalidations, scalar Turbo replacement, keyed ERB
  components, signed component locals, and authorized replace or morph refresh
- Reconciliation read APIs
- Installation doctor, authorization reference, fit guide, and legacy-state
  migration cookbook
- Handler Active Record write isolation, same-database commit actions, ambient
  transaction rejection, adapter lock/query deadlines, structured sync timeout
  diagnostics, and result recovery
- Bounded message/process pruning, actor-type opt-in instance expiration,
  graceful caller shutdown, committed state snapshots, and an opt-in Minitest
  helper
- SQLite, PostgreSQL, and MySQL integration suites
- Inline RBS generation/validation, Steep, Standard Ruby, Solid Queue's exact
  RuboCop policy, and a warning-free Brakeman scan

## Partially implemented

- Supervisor: starts and drains thread roles, but does not replace a crashed
  role or run periodic maintenance automatically.
- Wake-up strategy: in-process signaling plus durable polling and injection are
  implemented; PostgreSQL `LISTEN/NOTIFY` and optional Redis adapters are not.
- Realtime: scalar and dependency-driven keyed ERB component replacement or
  morphing, personalized refresh authorization, revision fencing, coalescing,
  and reconnect convergence are implemented; application-directed Turbo
  append intents are not.
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
3. Add result lookup by request ID and broader deadlock retry classification.
4. Add scheduled retention and stale-process maintenance.
5. Add database/server-version checks and MySQL InnoDB verification at boot.
6. Add Turbo append intents and expand reconnect coverage in a full browser.
7. Add distributed rate limits, global admission hooks, and cache-capacity
   eviction.
8. Expand security scanning and run compatibility CI across supported Rails and
   Ruby versions.
9. Benchmark all workloads under documented hardware/database settings and
   publish adapter-specific adoption measurements.

No production-ready claim should be made until these hardening milestones have
operational soak evidence.
