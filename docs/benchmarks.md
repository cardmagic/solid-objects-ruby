# Local benchmarks

These numbers are development measurements, not universal capacity guarantees.
They include the runtime's Active Record and database query overhead and will
vary with hardware, schema size, connection pools, durability settings, and
contention.

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

The scripts and invocation examples are in the
[development guide](development.md#benchmarks). PostgreSQL and MySQL should be
benchmarked independently before selecting production capacity.
