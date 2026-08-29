# Performance and storage costs

These numbers are development measurements. They do not guarantee capacity.
They include the runtime's Active Record and database query overhead, and they
change with hardware, schema size, connection pools, durability settings, and
contention.

## Idle SQLite polling

Run the four-role idle harness with:

```bash
bundle exec ruby -Ilib benchmark/idle_polling.rb
```

It warms each interval for three seconds, measures for ten seconds, and reports
process user plus system CPU time divided by wall time. Measured August 16,
2026 on an Apple M5 with Ruby 4.0.6 and SQLite 3.53.2. The before run used
0.13.0; the after run used the prepared 0.13.1 tree.

| Fast interval | Before polls/s | Before CPU | After polls/s | After CPU |
| ---: | ---: | ---: | ---: | ---: |
| 20 ms | 165.340 | 8.401% | 3.998 | 0.947% |
| 100 ms | 38.396 | 2.925% | 3.999 | 0.482% |
| 500 ms | 7.998 | 2.061% | 3.996 | 0.283% |

The after run reached the one-second ceiling for the actor, effect, reminder,
and broadcast roles. These are developer-laptop measurements, not a CPU
guarantee; timer scheduling, YJIT, the SQLite file, and unrelated host activity
affect short samples.

Five SQLite samples measured durable enqueue through committed completion after
2.5 seconds of idleness. The polling-only multi-process harness submits just
after an empty pass, so it measures approximately the full polling wait rather
than average arrival latency.

| Topology | 0.13.0 p50 | Prepared 0.13.1 p50 |
| --- | ---: | ---: |
| One process, in-process wake-up | 43.360 ms | 50.339 ms |
| Two processes, polling only | 117.787 ms | 1,028.006 ms |

The local wake-up keeps the one-process path prompt after backoff. The
polling-only row is the explicit tradeoff: use PostgreSQL notifications or
optional Redis Pub/Sub when separate processes need low-latency delivery.

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
`bundle exec ruby benchmark/query_count.rb`, which is deterministic across runs:

| Scenario | Queries |
| --- | ---: |
| One message turn | 26 |
| The caller of one synchronous call | 49 |
| One synchronous call, caller plus the turn it waits on | 75 |

A worker turn fell from the 29 recorded earlier. The caller count is unchanged
at 49, and the combined figure is new: a synchronous call is a caller and a
worker turn, and only the sum says what the database actually serves.

Counting is scoped to the measuring thread. A worker loop polls whether or not
a call is in flight, so a process-wide count folds however many polls happened
to land inside the window into the result. That is also why the caller and the
turn are measured separately rather than by watching both threads at once.

A synchronous call costs far more queries than a worker turn because the caller
also registers or heartbeats its caller process, claims the activation, and
observes the result. Query count, not query time, dominates synchronous latency
on a networked database: measured locally against SQLite, database time is
roughly 5% of a call and the remaining 95% is Ruby.

The difference between the SQLite development result and the MySQL adoption
result is why Solid Objects does not publish one latency promise. Network
topology, adapter behavior, host schema, logging, callbacks, and contention all
matter.

## State size and committed throughput

A turn commits the whole state image. It copies the state, encodes it, and
writes the row, so every message pays for the size of the state its actor
keeps. Run the scenario with:

```bash
COUNT=300 bundle exec ruby -Ilib benchmark/state_size.rb
```

Measured 2026-08-29 on an Apple M5 with 24 GB RAM, Ruby 4.0.5, Rails 8.1.3.1,
and SQLite 3.53.2. One hot actor received 300 messages at each state size. Each
figure is the median of five runs, and the two trees ran one after the other in
each round. The state holds many small entries, because a copy visits every
node, and one long string of the same length costs much less. The harness sets
`warn_state_bytes` to the hard limit, so neither tree pays for an event that
only one of them can emit.

| Committed state | Before | After | Change |
| ---: | ---: | ---: | ---: |
| 23 bytes | 1,268.0 messages/s | 1,252.5 messages/s | -1.2% |
| 13,662 bytes | 624.1 messages/s | 654.1 messages/s | +4.8% |
| 118,786 bytes | 169.3 messages/s | 174.6 messages/s | +3.1% |
| 1,026,356 bytes | 21.6 messages/s | 23.8 messages/s | +10.2% |

The "before" tree copied the whole state three times per committed turn and
encoded a string that it discarded whenever the caller gave no byte limit. The
"after" tree copies it twice and encodes only where a limit applies. It also
checks the encoding of every string it normalizes, which the discarded encoding
used to do, so part of the saving pays for that check. The gain grows with the
state, because the database write dominates a small turn. The empty-state row
sits inside run-to-run variance.

The curve matters more than the change. Throughput falls about 28 times between
13 KB and 1 MB of state, and about 53 times between an empty state and 1 MB.
The `max_state_bytes` default of 5 MB is therefore a limit rather than an
operating point. `warn_state_bytes` defaults to 64 KB, and each commit above it
reports `solid_objects.state.large`. The Node package carries the same setting
as `warnStateBytes` and defaults it to 128 KB, because its measured curve falls
later: it keeps 98% of its empty-state throughput at 16 KB, where this gem
keeps 52% at 13 KB.

These are developer-laptop numbers on one adapter. They show shape and ratio,
not a capacity guarantee.

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
