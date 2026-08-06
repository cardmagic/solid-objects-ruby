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
| Queries for one message turn | 29 |

The difference between the SQLite development result and the MySQL adoption
result is why Solid Objects does not publish one latency promise. Network
topology, adapter behavior, host schema, logging, callbacks, and contention all
matter.

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

Version 0.2 has cleanup indexes but no built-in pruning command. Budget message
growth as:

```text
daily durable messages = daily actor writes + daily actor reads + daily callbacks
```

Review the [retention requirements](operations.md#retention-and-backups) before
adopting a high-volume surface.

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
