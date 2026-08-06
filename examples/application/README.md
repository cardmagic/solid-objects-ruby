# Example application source

This directory contains the host-application pieces for the shopping cart and
chat room examples. Copy them into a Rails application that has run
`bin/rails generate solid_objects:install`, mount the engine for administration,
and start the runtime with `bundle exec solid_objects start`.

The payment adapter receives the durable effect ID as its provider idempotency
key. The chat actor also gives every submitted chat message a caller-generated
message ID and checks that ID in durable actor state, because actor handlers may
be redelivered.

The views demonstrate initial `solid_object` rendering and live observable
replacement. Live cart-summary replacement and chat-message append are
deliberately not shown as working behavior because component broadcasts and
Turbo append intents remain roadmap items.
