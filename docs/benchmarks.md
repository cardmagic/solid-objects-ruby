# Performance and storage costs

These numbers are development measurements, not universal capacity guarantees.
They include the runtime's Active Record and database query overhead and will
vary with hardware, schema size, connection pools, durability settings, and
contention.

## Production-shaped adoption measurement

An adoption evaluation measured Solid Objects 0.2.0 from a macOS Rails process
against Docker MySQL 8 over a published TCP port. The host used Rails 8.1, Ruby
4.0.5, roughly 165 gems, and an approximately 2,200-line schema.

| Operation | Existing key-value row | Solid Objects |
| --- | ---: | ---: |
| Write | median 4.7 ms | median 60 ms, minimum 33 ms, maximum 163 ms |
| Read | median 0.2 ms | median 28 ms |
| First call for a cold identity | approximately 5 ms | 315 ms |

This is not a controlled cross-database benchmark and no sample count was
recorded. It is still useful adoption evidence: a synchronous actor call is not
a substitute for a direct indexed row read when single-digit-millisecond
latency is the requirement. The first call includes actor-instance creation,
caller-process registration, message enqueue, activation claim, handler
execution, fenced commit, and activation release.

## Project development benchmark

Measured 2026-08-06 on an Apple M5 with 24 GB RAM, Ruby 4.0.5, Rails 8.1.3.1,
and SQLite 3.51.0. Each throughput scenario used 200 operations; the concurrent
scenario used four worker threads.

| Scenario | Result |
| --- | ---: |
| Enqueue, one actor | 629.2 messages/s |
| Claim, 200 actors | 1,038.4 claims/s |
| Process, 40 actors round-robin | 548.1 messages/s |
| Process, 200 cold actors | 121.5 messages/s |
| Process, one hot actor | 726.4 messages/s |
| Process, four workers | 556.5 messages/s |
| Synchronous latency | p50 1.8 ms, p95 25.6 ms, p99 156.2 ms |
| Activation reuse | 98.0%, four activations for 200 messages |

Query counts are a property of the code rather than the host, so they are
tracked separately. Re-measured 2026-08-10 against 0.10.0 on SQLite with
`bundle exec ruby benchmark/query_count.rb`, which reports both and is
deterministic across runs:

| Scenario | Queries |
| --- | ---: |
| One message turn | 26 |
| One synchronous call | 53 |

Both numbers moved since they were first recorded, in opposite directions: a
worker turn fell from 29 and a synchronous call rose from 49. The synchronous
count had no script behind it until now, which is why it drifted unnoticed.

A synchronous call costs far more queries than a worker turn because the caller
also registers or heartbeats its caller process, claims the activation, and
observes the result. Query count, not query time, dominates synchronous latency
on a networked database: measured locally against SQLite, database time is
roughly 5% of a call and the remaining 95% is Ruby.

The difference between the SQLite development result and the MySQL adoption
result is why Solid Objects does not publish one latency promise. Network
topology, adapter behavior, host schema, logging, callbacks, and contention all
matter.

## Reactive delivery paths

Measured 2026-08-09 on an Apple M5 with 200 iterations, for one actor mutation
that changes three components.

| Delivery path | Browser requests | Server render time |
| --- | ---: | ---: |
| Individual component refreshes | 3 | 0.535 ms |
| Batched refresh | 1 | 0.249 ms |
| State payload broadcast | 0 | 0.100 ms |

The request column is the headline. Server render time is small in every path,
so the win is not faster rendering, it is fewer round trips: each individual
refresh costs a full HTTP request through the Rails middleware stack, and a
batch replaces three of those with one. A state payload removes the HTTP leg
entirely by travelling on the Action Cable connection the page already holds.

These are server-side numbers. They do not include network latency, Action
Cable delivery, or browser rendering, which dominate wall-clock time in a real
deployment and make the request-count difference matter more than it appears
here. End-to-end latency against a deployed application has not been measured.

## Cross-process wake-up

Measured 2026-08-09 against PostgreSQL 17, 30 samples, with `polling_interval`
at its 100 ms default and a signal sent 2 ms after the waiter began.

| Wake-up strategy | p50 | p95 |
| --- | ---: | ---: |
| In-process `WakeUp` | 103.7 ms | 105.1 ms |
| `WakeUpAdapters::Postgresql` | 2.9 ms | 5.1 ms |

The in-process wake-up cannot reach another process, so a worker waits out the
full polling interval no matter how quickly the web process committed. The
notification adapter removes that floor rather than shrinking it, and the
polling interval remains the upper bound if a notification is missed.

## Durable row growth

The storage cost is deterministic even when latency is not:

- the first call for one actor identity inserts one
  `solid_objects_instances` row;
- every direct, `sync`, query, attribute read, or `async` call inserts one
  permanent `solid_objects_messages` row;
- ready and claimed membership rows exist only while the call is pending or
  executing;
- one caller process row is registered per application process that performs
  synchronous calls;
- effects and observable changes add outbox rows; and
- reminders add one row per named actor reminder.

Attribute reads are therefore not free snapshots from the instance row. They
are ordered durable query messages and grow message history exactly like
writes.

Built-in pruning previews by default and must be scheduled explicitly. Budget
message growth before retention as:

```text
daily durable messages = daily actor writes + daily actor reads + daily callbacks
```

Review the [retention requirements](operations.md#retention-and-backups) before
adopting a high-volume surface.

Use `reference.snapshot` for an authorized current-state read when mailbox
ordering is unnecessary. It avoids a message row but can observe state before
an in-flight turn commits.

## Measure the host application

Run the adoption benchmark against a dedicated empty database with the same
adapter and topology as production:

```bash
COUNT=25 \
SOLID_OBJECTS_DATABASE_URL=mysql2://localhost/solid_objects_benchmark \
bundle exec ruby -Ilib benchmark/adoption_latency.rb
```

It reports the first cold call, warm synchronous writes, ordered reads, and
durable instance/message growth. Run it near the application process, with
production-like TLS and network boundaries where applicable.

The scripts and invocation examples are in the
[development guide](development.md#benchmarks). PostgreSQL and MySQL should be
benchmarked independently before selecting production capacity.
