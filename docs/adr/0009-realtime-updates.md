# ADR 0009: Realtime Updates Use a Durable Broadcast Outbox

- Status: Accepted
- Date: 2026-08-05

## Context

Action Cable broadcasts are online-only. A transaction can roll back, a broadcast process can crash, and a client can disconnect.

## Decision

The executor evaluates declared observables before and after a successful message. Changed values create broadcast outbox records inside the message commit. A broadcast worker delivers Turbo Stream replacements after commit.

One `solid_object` block creates one signed Action Cable subscription and contains stable targets for multiple observables and components. Subscription authorization runs after token verification and before streaming. Reconnect refresh reads current actor state; the broadcast stream is an optimization, not state.

## Consequences

- Disconnected clients may miss individual broadcasts but can converge by refresh.
- Broadcast delivery is at least once and replacements must be idempotent.
- Actor IDs and signed stream names are identifiers, not authorization.
- Realtime support is optional and loaded only when Action Cable and Turbo are present.
