# Is Solid Objects a good fit?

Solid Objects trades database work and retained message history for one strong
property: all committed turns for one durable identity execute in order behind
a fenced activation. Adopt it when that coordination property removes
application-level locking, recovery, and scheduling code that would otherwise
be difficult to make correct.

## Strong fit signals

Solid Objects is a good candidate when most of these are true:

- State belongs to one durable identity such as a cart, room, device, session,
  workflow, or user-specific schedule.
- Writes for that identity must be serialized.
- The state is naturally a bounded JSON document.
- The object needs per-identity reminders, transactional external effects, or
  reactive Rails views.
- Different identities should run concurrently while one hot identity remains
  deliberately sequential.
- A durable mailbox and at-least-once retry are more valuable than minimum
  request latency.
- The application can operate and monitor additional database tables and, for
  asynchronous features, a Solid Objects runtime process.

Typical fits include checkout state machines, collaborative rooms, device
twins, durable assessments, approval workflows, and user-specific scheduling.

## Poor fit and anti-patterns

Prefer ordinary Active Record, cache storage, Active Job, or an event pipeline
when any of these dominate:

- High-QPS request-path reads. Every actor attribute read is an ordered durable
  message, not a direct `SELECT`, and retains a message-history row.
- Hot counters such as abuse limits, impressions, page views, or metrics. One
  identity is a serialization point and cannot gain throughput by adding
  workers.
- High-volume append workloads. Actor state rewrites a JSON document and the
  mailbox retains one durable message per call.
- Latency budgets where tens of milliseconds are already unacceptable.
- Large, relational, or query-heavy state. Keep that data normalized in
  application tables.
- CPU-heavy work or slow network I/O inside a handler.
- Cross-actor transactions or synchronous actor-to-actor call graphs.
- State that is clearer as a normal record with database constraints and direct
  service methods.

A rate limiter is usually a poor actor: it is hot, request-critical, and often
expires rather than requiring permanent message history. An impressions
pipeline is also a poor actor: its value is high-throughput append and
aggregation, not serialized mutable state.

## Cost model

Every synchronous or asynchronous invocation:

- inserts one permanent `solid_objects_messages` row;
- briefly occupies one ready or claimed membership row;
- performs several short coordination transactions; and
- may add effect, broadcast, or reminder records.

The first call for an identity also inserts one `solid_objects_instances` row.
Each application process that performs synchronous calls registers one caller
process row. Actor state is rewritten as a JSON value on each successful
mutation.

There is no built-in retention command in 0.2. Completed message history grows
until the host application implements a reviewed retention policy. See
[performance measurements](benchmarks.md) and
[retention guidance](operations.md#retention-and-backups).

## Decision checklist

Before adopting an actor, answer:

1. What exact race or lifecycle problem requires serialized per-identity turns?
2. What is the canonical actor identity?
3. How hot can one identity become?
4. Can the request path tolerate the measured cold and warm latency?
5. How many calls and durable rows will this surface create per day?
6. Which calls can be asynchronous?
7. Which effects need downstream idempotency?
8. Which runtime roles and operational alerts will the feature require?
9. How will completed messages and outbox history be retained?
10. How will existing state be cut over and rolled back?

Benchmark the actual host database and deployment topology before committing a
latency-sensitive surface. Local benchmark results are evidence about query
shape, not universal capacity guarantees.
