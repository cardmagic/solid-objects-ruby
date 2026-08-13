# Roadmap

## Implemented and tested

- Rails engine, install generator, migration, and CLI
- Explicit actor registry, references, JSON state, and state migrations
- Fluent direct synchronous RPC, configured `sync`, and durable `async`
- Durable message history plus ready/claimed membership tables
- Concurrent sequence allocation and actor creation
- Activation leases, renewal, unique activation tokens, generations, and
  fenced commits
- Bounded activation passes, idle cache, hot-actor yield, and process records
- At-least-once retries, terminal domain rejection, strict poison ordering,
  dead letters, and tail retry
- Transactional effects with success/failure actor messages carrying the
  originally staged arguments for callback correlation
- Actor-to-actor asynchronous outbox delivery. Effects and broadcasts use
  portable status rows with polling indexes and database check constraints on
  status, which works on all three adapters; a future version may add narrow
  ready/claimed membership tables for very large outboxes, as messages already
  have
- One-shot and recurring reminders with `:latest` or `:all` catch-up, exercised
  through a real `solid_objects start` worker as well as in process. They were
  listed here while broken in that worker: the scheduler reached a constant the
  caller path happened to load, so reminders never fired in production and
  every in-process test still passed
- Durable value or invalidation-only observable broadcasts, scalar Turbo
  replacement, keyed ERB components, signed component locals, and authorized
  replace or morph refresh. Invalidation-only observables retain component
  change detection while storing and broadcasting no projected value
- Batched component refreshes: components sharing a signed `batch:` collapse to
  one browser request per revision, served as HTML frames in a JSON envelope
- Personalized state payload broadcasts computed per subscriber under that
  subscriber's authorization context, fenced by actor revision, resolved through
  `payload_authorization_context` so the block and `authorize_query` see the
  same subject a controller render passes, and confined so one failing payload
  cannot reject the subscription or stop its siblings
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
  helper that clears every actor-owned table itself rather than relying on the
  database cascade, which a host application may not enforce, and runs due
  reminders against an explicit test time without moving the database clock
- Supervisor role replacement: a role whose thread dies is restarted until
  shutdown is requested, and dead process records plus expired message and
  process history are pruned on their own intervals without an application
  scheduling its own job
- SQLite, PostgreSQL, and MySQL integration suites, with MySQL run against both
  the `mysql2` and `trilogy` clients because an adapter name, a connection
  collation, and an error code name all differ between them
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
  a commit SHA. The browser suite covers the reconnect burst: convergence of
  batched and unbatched components, an inert replay of an applied revision,
  cancellation of the request left in flight by the drop, incarnation ordering
  after a destroy and recreate, and payload delivery exactly once per revision

## Partially implemented

- Wake-up strategy: in-process signaling, durable polling, injection, and
  cross-process adapters for PostgreSQL and Redis are implemented and tested.
  What is not done is making any of them automatic. In-process signaling cannot
  cross process boundaries, so by default a commit in a web process does not
  wake a broadcast executor in a worker process and that delivery waits up to
  `polling_interval`, 100 ms. An adapter removes that floor, measured at 103.7 ms
  to 2.9 ms at p50 on PostgreSQL and 103.8 ms to 5.7 ms on Redis, but each stays
  opt-in for a reason: the PostgreSQL adapter opens a connection per waiting
  thread outside the pool and `LISTEN` does not survive a transaction-pooling
  proxy such as PgBouncer, and Redis is not a dependency of this gem.
  `WakeUpAdapters.for` selects notifications on PostgreSQL and the in-process
  default elsewhere; it never selects Redis. An application that configures
  nothing keeps polling, and MySQL applications keep polling unless they
  configure Redis explicitly.
- Realtime: scalar and dependency-driven keyed ERB component replacement or
  morphing, personalized refresh authorization, revision fencing, coalescing,
  reconnect convergence, batched refreshes, and personalized state payloads are
  implemented; application-directed Turbo append intents are not. Batch
  coalescing happens in the browser rather than the broadcast executor, so one
  commit still sends one Action Cable message per changed observable even
  though it costs one browser request. Reconnect convergence previously
  bypassed batching entirely, issuing one request per stale component at the
  moment a restart reconnects every client at once; it now shares the batching
  the live invalidation path uses. Payload delivery over Action Cable was
  untested end to end, which is how a raising payload block came to reject the
  subscription; it is now covered and confined, and the payload authorization
  context is resolved through `payload_authorization_context` rather than
  handing the block a raw Cable connection.
- Backpressure: mailbox/payload/state/result caps and fair yields exist;
  distributed per-actor rate limits and global admission control do not.
- Administration: actor and dead-letter views plus policy hooks exist; richer
  filtering, audit records, and bulk-safe tools do not.

## Next milestones

1. Add result lookup by request ID and broader deadlock retry classification.
2. Add Turbo append intents.
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
