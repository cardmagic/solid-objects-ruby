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
- Batched component refreshes: components sharing a signed `batch:` collapse to
  one browser request per revision, served as HTML frames in a JSON envelope
- Personalized state payload broadcasts computed per subscriber under that
  subscriber's authorization context, fenced by actor revision
- Reconciliation read APIs
- Installation doctor, authorization reference, fit guide, and legacy-state
  migration cookbook
- Database server verification: each adapter reports its version against a
  tested minimum, MySQL confirms Solid Objects tables use InnoDB, and the
  doctor warns rather than refusing to run on an untested server
- Handler Active Record write isolation, same-database commit actions, ambient
  transaction rejection, adapter lock/query deadlines, bounded SQLite lock
  retries outside those deadlines, structured sync timeout diagnostics, and
  result recovery
- Bounded message/process pruning, actor-type opt-in instance expiration,
  graceful caller shutdown, committed state snapshots, and an opt-in Minitest
  helper
- Supervisor role replacement: a role whose thread dies is restarted until
  shutdown is requested, and dead process records plus expired message and
  process history are pruned on their own intervals without an application
  scheduling its own job
- SQLite, PostgreSQL, and MySQL integration suites
- Opt-in cross-process wake-up on PostgreSQL through `WakeUpAdapters.for`, with
  a listening connection per waiting thread and release on supervisor shutdown
- Opt-in cross-process wake-up on Redis, the option for MySQL applications,
  measured at 103.8 ms to 5.7 ms at p50; the `redis` gem stays outside this
  gem's dependencies
- Inline RBS generation/validation, Steep, Standard Ruby, Solid Queue's exact
  RuboCop policy, and a warning-free Brakeman scan
- Compatibility CI across the supported span: Ruby 3.3, 3.4, and 4.0 against
  Rails 8.0 and 8.1, pinned through `RAILS_VERSION` so the advertised range is
  verified rather than assumed
- A JavaScript suite covering every browser module, run in CI with Node's test
  runner and jsdom, plus a browser suite running the same modules against real
  Chromium and a real Turbo build, with every GitHub Actions reference pinned to
  a commit SHA

## Partially implemented

- Wake-up strategy: in-process signaling, durable polling, injection, and an
  opt-in PostgreSQL notification adapter are implemented; a Redis adapter is
  not. In-process signaling cannot cross process boundaries, so without the
  adapter a commit in a web process does not wake a broadcast executor in a
  worker process and that delivery waits up to `polling_interval`, 100 ms by
  default. `WakeUpAdapters.for` removes that delay on PostgreSQL, measured at
  103.7 ms to 2.9 ms at p50. It is opt-in rather than automatic: it opens a
  connection per waiting thread outside the pool, and `LISTEN` does not survive
  a transaction-pooling proxy such as PgBouncer. MySQL has no notification
  primitive, so MySQL applications keep polling unless they configure the Redis
  adapter.
- Realtime: scalar and dependency-driven keyed ERB component replacement or
  morphing, personalized refresh authorization, revision fencing, coalescing,
  reconnect convergence, batched refreshes, and personalized state payloads are
  implemented; application-directed Turbo append intents are not. Batch
  coalescing happens in the browser rather than the broadcast executor, so one
  commit still sends one Action Cable message per changed observable even
  though it costs one browser request.
- Backpressure: mailbox/payload/state/result caps and fair yields exist;
  distributed per-actor rate limits and global admission control do not.
- Administration: actor and dead-letter views plus policy hooks exist; richer
  filtering, audit records, and bulk-safe tools do not.
- Outboxes use portable status rows with polling indexes; future versions may
  introduce narrow ready/claimed membership tables for very large outboxes.

## Next milestones

1. Add result lookup by request ID and broader deadlock retry classification.
2. Add Turbo append intents and expand reconnect coverage in a full browser.
3. Add distributed rate limits, global admission hooks, and cache-capacity
   eviction.
4. Expand security scanning beyond the Brakeman scan, such as dependency
   auditing and secret scanning.
5. Benchmark all workloads under documented hardware/database settings and
   publish adapter-specific adoption measurements. Throughput, synchronous
   latency, query counts, and the three reactive delivery paths are measured on
   SQLite; adapter-specific and end-to-end browser measurements are not.

No production-ready claim should be made until these hardening milestones have
operational soak evidence.
