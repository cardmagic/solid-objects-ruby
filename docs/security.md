# Security guide

## Policy hooks

Solid Objects has separate hooks for sending messages, querying state,
destroying actors, subscribing to actor streams, and administration. The host
application supplies the authenticated request or connection as
`authorization_context`. All five hooks deny by default.

The [authorization reference](authorization.md) lists the caller context and
risk for every hook and includes a tenant-aware policy example.

Method-style reference calls do not bypass these hooks. Public instance methods
declared on an actor are part of its remotely addressable message surface and
delegate to the authorized synchronous invocation path. Keep implementation
helpers private or protected. Query, attribute, observable, and committed
`snapshot` reads use the separate query authorization policy. Explicit `async`
message delivery uses the same message authorization policy as direct calls.
Recovering a timed-out result through `MessageReference#wait` reauthorizes the
stored operation.
`reference.destroy` delegates to `authorize_destroy` before checking whether
the actor exists, so denial does not reveal actor existence.

Internal runtime delivery bypasses the public client only for rows already
created by a committed actor turn. It never converts a database actor type into
a Ruby constant.

## Actor identity

Actor IDs are identifiers, not capabilities. Treat user-supplied IDs as
untrusted and verify tenancy/ownership in every public policy hook. The registry
maps explicit type strings to actor classes; arbitrary constantization is
forbidden.

Opaque stream and DOM names reduce accidental disclosure but do not replace
authorization. Signed stream tokens are readable by their recipient and prove
integrity only.

Observables are invalidation-only by default, so their durable rows and shared
actor stream carry no projected value. `broadcast: :value` deliberately stores
the value in the broadcast outbox and may send it to every subscriber that
passes `authorize_subscription` for the actor. Never opt credentials, session
identifiers, private cards, hidden library order, or any other
subscriber-specific state into value broadcasting. Use `broadcast_payload` for
a projection that must be computed separately for each authorized connection.

## Serialization

The built-in serializer accepts JSON-compatible data, normalizes keys to
strings, rejects colliding normalized keys, limits nesting and byte size, and
rejects non-finite numbers. It never loads Ruby objects with `Marshal`.

Database access is still privileged input. Restrict who can write runtime
tables, because a malicious row can request registered messages or effects even
without unsafe object deserialization.

## Administration

The engine controllers and dead-letter service deny access unless
`authorize_administration` approves. Actor state, arguments, results, errors,
and backtraces may contain sensitive application data. Keep admin routes behind
host authentication and audit their use.

Instrumentation excludes arguments, state, results, and effect payloads by
default. Review custom logging and effect handlers for accidental disclosure.

## Handler database access

Handlers, observables, lifecycle hooks, and state migrations run with Active
Record writes prevented. They may query application records, but a direct
write becomes
`SolidObjects::ApplicationWriteForbidden` and dead-letters without retry.
This prevents application data from escaping a later actor failure or stale
fence.

Registered commit actions are privileged application code. They execute inside
the fenced actor transaction and receive stored JSON arguments, so register
only fixed names, validate record ownership again, and keep the block to
bounded database work. Never perform network I/O or authorize solely from a
record ID in commit-action arguments.

Actor destruction is not an administrative shortcut. Authorize tenancy and
ownership explicitly in `authorize_destroy`; knowledge of an actor ID is never
permission to delete its state or queued work.

Instance pruning is likewise destructive and requires administration
authorization. Only opt-in actor types are eligible, and live work is
preserved, but the host application must decide whether dormant state and
completed history may expire.

## Denial of service

Configure mailbox and byte limits. Add host rate limiting before public actor
calls. One actor is intentionally sequential, so an attacker who can target a
single identity can create a hot-actor bottleneck even when the global worker
pool has capacity.
