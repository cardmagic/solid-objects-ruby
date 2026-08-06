# Security guide

## Policy hooks

Solid Objects has separate hooks for sending messages, querying state,
destroying actors, subscribing to actor streams, and administration. The host
application supplies the authenticated request or connection as
`authorization_context`. All five hooks deny by default.

Method-style reference calls do not bypass these hooks. Public instance methods
declared on an actor are part of its remotely addressable message surface and
delegate to the authorized `tell` path. Keep implementation helpers private or
protected. Query and attribute methods delegate to the authorized `ask` path.
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

Actor destruction is not an administrative shortcut. Authorize tenancy and
ownership explicitly in `authorize_destroy`; knowledge of an actor ID is never
permission to delete its state or queued work.

## Denial of service

Configure mailbox and byte limits. Add host rate limiting before public actor
calls. One actor is intentionally sequential, so an attacker who can target a
single identity can create a hot-actor bottleneck even when the global worker
pool has capacity.
