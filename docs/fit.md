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
twins, durable assessments, approval workflows, user-specific scheduling, and
low-rate quotas that a reminder refills.

A workflow fits when one entity owns the mutable state and its mailbox holds
the step order. A durable execution engine that replays named steps from a step
log is a different tool: Solid Objects redelivers an ordered message and
retries it, and does not replay a handler from a step log.

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

A request-path rate limiter is usually a poor actor: it is hot,
request-critical, and often expires rather than requiring permanent message
history. A low-rate quota is the case that does fit, such as five password
resets an hour for one account, where a reminder refills the bucket and each
check is one durable ordered message. An impressions pipeline is also a poor
actor, because its value comes from high-throughput append and aggregation. It
does not need serialized mutable state.

[Solid Objects Pro](https://solidobjects.pro/) is the commercial scaling layer
for the high-QPS cases in this section. Grouped operations coalesce concurrent
calls into one bulk insert. Ephemeral operations hold a loss-tolerant call in
process memory and write no journal row, which is the mode for an abuse limiter,
a presence signal, or a view count. Reactive projections materialize a read
model from the durable broadcast outbox, so request-path reads stop competing
with mailbox work.

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

Built-in bounded pruning is explicit and dry-run by default. Configure global
and per-actor-type message retention, then schedule the reviewed execute
commands. Actor instances expire only for types explicitly listed in
`instance_retention_by_actor_type`. See
[performance measurements](benchmarks.md) and
[retention guidance](operations.md#retention-and-backups).

Actor handlers may read application records but may not write them directly.
Use a same-database commit action for a short atomic database change or an
idempotent effect for external work. If the domain needs broad relational
updates throughout arbitrary handler code, an ordinary Active Record service
is likely a clearer fit.

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
latency-sensitive surface. Local benchmark results show query shape. They do
not guarantee capacity.
