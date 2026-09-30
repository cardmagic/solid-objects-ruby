# Portable observability

Configure `instrumentation(event)` to receive structured events. No exporter SDK
is required. The same JSON envelope is emitted by Ruby, SQLite, PostgreSQL, MySQL,
and the Durable Objects host. Existing JavaScript `name`, `occurredAt`, and
`attributes` fields remain available. Ruby's Active Support notifications remain
available with their existing snake_case payloads.

## Schema version 1

Every event has `schemaVersion`, `name` (prefixed with `solid_objects.`),
`occurredAt` (UTC ISO 8601), `adapter`, `actorType`, `actorId`, `incarnation`,
`revision`, `messageId`, `attempt`, `attributes`, and `metrics`.
Unavailable identifiers are null; `attempt` is zero outside a message attempt.
An incarnation identifies a persisted actor instance, independently of its lease
generation. Revisions and IDs are strings. Process-wide events have null actor
identity. A message ID or revision correlates actor work where applicable.

Only known scalar metadata fields enter the portable envelope. Arguments, state,
results, credentials, backtraces, exception text, nested provider data, and unknown
attributes are excluded. Actor IDs remain correlation data: applications should
use opaque actor identifiers and apply their own retention policy to event logs.
Events and metric samples are immutable. Throwing observers, rejected observer
promises, and a failing instrumentation error logger cannot change a turn's
result. Delivery is best effort and synchronous callbacks should be short;
JavaScript does not await exporters. Telemetry is not a durable audit trail.

| Event | Meaning |
| --- | --- |
| `activation.started/completed/failed` | Local actor activation hook lifecycle |
| `message.started/completed/failed/rejected` | One attempt's execution outcome |
| `message.retry` | Failed attempt durably queued for another attempt |
| `dead_letter.created` | Message exhausted retries or failed permanently |
| `mailbox.depth` | On-demand diagnostic sample; exact depth only if not truncated |
| `reminder.enqueued` | Due reminder dispatch; lateness is measured from due time |
| `outbox.age` | Delivery observation; age is time since the item's current availability time |
| `recovery.reclaimed` | A previously claimed, interrupted message begins another attempt |
| `recovery.completed/failed` | Durable effect recovery callback commits or enters the dead-letter queue |
| `snapshot.read` | Authorized snapshot constructed without exposing its contents |
| `realtime.connected/disconnected` | Actor subscription added or removed |

Events describe local observations. Concurrent deletion, crashes, and failed
exporters can omit events. Never infer exactly-once delivery from event counts.
Additional existing runtime events retain their names.

## Metrics and tracing

Metrics are sample descriptions. Exporting them is opt-in: the runtime does not
register meters, allocate per-actor metric series, or install a vendor SDK.

| Name | Kind | Unit | Aggregation |
| --- | --- | --- | --- |
| `solid_objects.events` | counter | `1` | Sum one per event |
| `solid_objects.duration` | histogram | `ms` | Distribution of observed attempt duration |
| `solid_objects.reminder.lateness` | histogram | `ms` | Distribution of reminder dispatch delay |
| `solid_objects.outbox.age` | histogram | `ms` | Distribution of delivery delay since availability |
| `solid_objects.mailbox.depth` | gauge | `1` | Last exact sampled actor depth; omit truncated samples |

Labels contain only event name, adapter family, and declared actor type. Keep the
actor type registry finite. Never add actor ID, incarnation, message ID, operation
arguments, request IDs, or error text to metric labels. A gauge without an actor
label represents the most recently observed actor; it is not total fleet backlog.
For tracing, correlate start/outcome events using `adapter`, `incarnation`,
`messageId`, and `attempt`, and close or expire spans when no outcome arrives.

## Actor observers and diagnostics

```ruby
cart = ShoppingCart.ref("demo-cart")
stop = cart.observe(authorization_context: operator) do |event|
  logger.info(event.to_json)
end
summary = cart.diagnostics(authorization_context: operator, limit: 50)
stop.call
```

Ruby uses `reference.observe(authorization_context:) { |event| ... }` and
`reference.diagnostics(authorization_context:, limit: 50)`. Stop observing by
calling the returned proc. `on` filters one event name, such as `message.retry`.
Observers receive only this actor's events in the current runtime/process; they
are not subscriptions to workers on other hosts. Dispose them when the caller's
session ends or authorization is revoked. JS limits local observers to 1,000.
For remote Durable Objects, configure `instrumentation` on the actor host and
filter by actor identity there; process-local reference observers raise
`UnsupportedCapability`. Remote `reference.diagnostics` is supported.

Both APIs default to denied. Set `authorizeAdministration` / `authorize_administration`
to allow action `observe` or `inspect`, resource `actor_diagnostics`, and resource ID
`JSON.stringify([actorType, actorId])`. Ruby receives a symbol action. Authorization
runs before reading summaries or registering observers; possessing an actor ID
confers no permission.

Diagnostics read at most `limit + 1` rows per queue source, with a hard limit of
100. Each category returns `sampled`, `truncated`, and `oldestAgeMilliseconds`.
The limit applies to each combined category: one effect plus one broadcast with
`limit: 1` returns `sampled: 1, truncated: true`, even when both source queries
returned all their rows. The extra row proves that the category exceeds its cap.
The last value measures nonnegative time since availability (or terminal failure
for recovery callbacks); future reminders have zero age. No payloads or row
identifiers are returned. Samples are observations across several queries,
not an atomic fleet snapshot. Large queues can still require database scanning;
the bound limits materialized rows and response size, not query execution time.

Categories are mailbox (ready and claimed), outbox (pending and processing effects
and broadcasts), reminders (scheduled and paused), retries (failed messages still
eligible to run), and recoveryFailures (dead internal effect recovery
callback messages). Durable Objects does not implement process-heartbeat effect recovery;
its recoveryFailures category is empty. Recovery failures are durable records,
not a history of transient database or exporter exceptions.

## A query that works across adapters

Write one envelope per line to `events.jsonl`, using the same instrumentation hook
with SQLite and PostgreSQL. This query reports completed attempts by adapter:

```sh
jq -s 'map(select(.name == "solid_objects.message.completed"))
  | group_by(.adapter)
  | map({adapter: .[0].adapter, completed: length,
         mean_ms: (map(.attributes.durationMilliseconds) | add / length)})' events.jsonl
```

A dashboard can chart the event counter by adapter and outcome and the duration,
reminder lateness, and outbox age distributions using exactly the same fields.
Compare workloads with the same actor types and sampling policy. Counts measure
observations and cannot replace a database query for authoritative queue state.
