# The transmit family

The transmit family replays one runtime's actor operations onto another
runtime over a shared wire contract. The Ruby gem holds both sides:

- `Actor#transmit` and `SolidObjects.register_transmit` stage and deliver
  envelopes. This is the sending side.
- `SolidObjects::Transmission.receive(envelope)` ingests envelopes. This is
  the receiving side.

[solid-objects-js](https://github.com/cardmagic/solid-objects-js) holds the
same two sides for the browser and Node. A browser actor stages a transmit
intent with `this.transmit().increment({ amount })` in the same transaction
as its state change; its effect worker drains that outbox with
at-least-once delivery, per-actor order, and retry backoff, and posts one
JSON envelope per effect to a route the host application owns. A Rails
actor does the same with `transmit.increment(amount:)`. Either ingest
accepts either sender, so Rails-to-Rails, Rails-to-Node, Node-to-Rails,
and browser-to-Rails replication all ride one contract.

## The sending side

```ruby
class Counter < SolidObjects::Actor
  actor_type "counters"

  attribute :count, default: 0

  def increment(amount: 1)
    self.count += amount
    transmit.increment(amount:)
  end
end

SolidObjects.register_transmit do |envelope|
  DeliverToUpstream.call(envelope)
end
```

`transmit` returns the same fluent dispatcher `schedule` returns. It stages
one `solid-objects.transmit` effect in the same commit as the state change,
targeting the same operation on the same actor in the receiving runtime. For
a different target, stage the effect directly:

```ruby
emit "solid-objects.transmit",
  operation: "increment",
  arguments: { amount: 2 },
  actorType: "other-counters",
  actorId: "counter-1"
```

`SolidObjects.register_transmit(&deliver)` registers the drain handler for
that effect. The block receives one camelCase envelope per staged effect.
Raise inside the block while the upstream is unreachable; the effect
retries with backoff and dead-letters on exhaustion, like any other effect.

The drain keeps per-actor order across failures: a claimed transmit effect
delivers every undelivered sibling for its actor up to its own mailbox
sequence, oldest first. The receiving side dedups on `transmit:<effectId>`,
so a redelivered envelope applies once.

## Retry budget and offline tolerance

A raised delivery follows the effect retry policy: `max_attempts` (default
5) and `retry_delay` (default `2 ** (attempt - 1)` seconds, capped at 60).
The defaults give roughly fifteen seconds of offline tolerance before an
envelope dead-letters. An application that transmits across real outages
must raise both:

```ruby
SolidObjects.configure do |configuration|
  configuration.max_attempts = 30
  configuration.retry_delay = ->(attempt) { [ 2**(attempt - 1), 300 ].min.to_f }
end
```

These settings apply to every effect, not only transmits. A dead transmit
effect has no retry API; the dashboard lists it, and recovery means
returning its row to `pending` with a cleared `attempt_count`. Order
survives that recovery, because the drain orders by mailbox sequence, not
by retry time.

## Wire contract

The JS side owns the envelope format. The Ruby ingest accepts it verbatim.

- Keys arrive camelCase: `effectId`, `actorType`, `actorId`, `operation`,
  and an optional `arguments` object. There is no snake_case dialect.
- The idempotency key is `transmit:<effectId>`, byte-identical to the JS
  server ingest. A replayed envelope applies once.
- Delivery is at-least-once and per-actor ordered by the browser's drain.
  The server preserves mailbox order and adds no ordering of its own.

`compatibility/transmit-envelopes.json` pins the contract. Both runtimes
run a consuming test against the same fixture file.

## What `receive` does

1. It validates the envelope shape. A malformed envelope raises
   `SolidObjects::InvalidTransmission`.
2. It resolves the actor type and looks it up in the registry. On a miss
   under Rails it loads the application's actor classes once and retries,
   because a lazy-loading process has no other reason to have loaded the
   target class. A type that is still unknown raises
   `SolidObjects::UnknownActorType`. An undeclared operation raises
   `SolidObjects::UnknownMessage`.
3. It enqueues one internal message with the idempotency key
   `transmit:<effectId>`. Oversized arguments raise
   `SolidObjects::PayloadTooLarge` before persistence.

The enqueue uses `delivery_mode: "internal"`, the same mode the effect
executor uses. Internal delivery skips `authorize_message` by construction.
The host application must authenticate the request before it calls
`receive`.

## The engine route

The engine mounts `POST /solid_objects/transmit` (under wherever the host
mounts `SolidObjects::Engine`). It parses the body, authorizes it through
`authorize_transmission`, and passes it to `Transmission.receive` with the
configured `transmission_actor_type_resolver`. The policy denies by
default, because the ingest skips `authorize_message` by design; an
unauthorized envelope gets 403, and an envelope the server can never apply
gets 422:

```ruby
SolidObjects.configure do |configuration|
  configuration.authorize_transmission = lambda do |envelope:, authorization_context:|
    ActiveSupport::SecurityUtils.secure_compare(
      authorization_context.request.headers["Authorization"].to_s,
      "Bearer #{Rails.application.credentials.transmit_token}"
    )
  end
end
```

The policy receives the parsed envelope and the controller as
`authorization_context:`, so it can bind `actorType` and `actorId` to the
authenticated caller, not only check a shared token. Rate limits stay with
the host (Rack::Attack or the proxy), the same boundary the dashboard
draws.

## A hand-rolled route

An application that wants its own controller keeps the same shape:

```ruby
class TransmitController < ApplicationController
  skip_forgery_protection

  def create
    head :forbidden and return unless authenticated_device?

    SolidObjects::Transmission.receive(JSON.parse(request.body.read))
    head :ok
  rescue SolidObjects::InvalidTransmission, SolidObjects::UnknownActorType,
    SolidObjects::UnknownMessage, SolidObjects::PayloadTooLarge,
    SolidObjects::IdempotencyConflict, JSON::ParserError
    head :unprocessable_entity
  end
end
```

Return 422 for an envelope the server can never apply. The browser outbox
dead-letters that effect instead of retrying it forever. Return a 5xx for a
transient server fault, so the browser retries with backoff.
`SolidObjects::IdempotencyConflict` belongs in the 422 list: it means the
effect id was replayed with a different invocation, and no retry can ever
make that envelope apply.

## Actor type mapping

When both runtimes use the same actor type strings, no configuration is
needed. When the names diverge, pass `resolve_actor_type:` per call:

```ruby
SolidObjects::Transmission.receive(
  envelope,
  resolve_actor_type: ->(actor_type) { actor_type.sub("browser-", "server-") }
)
```

## Scope

Bidirectional replication as a first-class surface, where two runtimes
declare a replica pair and echo suppression keeps a replayed operation
from transmitting back, is a separate feature. The transmit family gives
it the mechanism; the declaration API does not exist yet.
