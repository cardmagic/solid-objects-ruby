# Transmit ingest

`SolidObjects::Transmission.receive(envelope)` is the server side of the
browser transmit family in
[solid-objects-js](https://github.com/cardmagic/solid-objects-js). A
solid-objects-js actor in a browser stages a transmit intent with
`this.transmit().increment({ amount })` in the same transaction as its state
change. The browser's effect worker drains that outbox with at-least-once
delivery, per-actor order, and retry backoff. It posts one JSON envelope per
effect to a route the host application owns. `Transmission.receive` replays
that envelope onto a server actor.

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
2. It resolves the actor type and looks it up in the registry. An unknown
   type raises `SolidObjects::UnknownActorType`. An undeclared operation
   raises `SolidObjects::UnknownMessage`.
3. It enqueues one internal message with the idempotency key
   `transmit:<effectId>`. Oversized arguments raise
   `SolidObjects::PayloadTooLarge` before persistence.

The enqueue uses `delivery_mode: "internal"`, the same mode the effect
executor uses. Internal delivery skips `authorize_message` by construction.
The host application must authenticate the request before it calls
`receive`.

## The host application owns HTTP

The gem draws the same boundary here that it draws for realtime transport:
the host owns the route, authentication, and rate limits.

```ruby
class TransmitController < ApplicationController
  skip_forgery_protection

  def create
    head :forbidden and return unless authenticated_device?

    SolidObjects::Transmission.receive(JSON.parse(request.body.read))
    head :ok
  rescue SolidObjects::InvalidTransmission, SolidObjects::UnknownActorType,
    SolidObjects::UnknownMessage, SolidObjects::PayloadTooLarge, JSON::ParserError
    head :unprocessable_entity
  end
end
```

Return 422 for an envelope the server can never apply. The browser outbox
dead-letters that effect instead of retrying it forever. Return a 5xx for a
transient server fault, so the browser retries with backoff.

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

`receive` is ingest only. The staging side in Ruby, an `actor.transmit` for
Ruby-to-Ruby replication, is a separate feature. An engine-mounted route
with an authentication hook is a possible follow-up; it stays out because
it carries authentication, CSRF, and rate-limit decisions of its own.
