# Database schema

The default prefix is `solid_objects_`. It is configurable before models and
migrations load. No partial indexes are used.

## Tables

### `instances`

One row per `(actor_type, actor_id)`. Stores JSON state, state version,
next-message sequence, activation owner/token/expiration/generation, pause
state, and lifecycle timestamps. The owner/token pairing is constrained so one
process row cannot make two concurrent activations appear identical.

Deleting an instance is the actor-incarnation boundary. Foreign keys cascade
the delete through messages, ready and claimed memberships, reminders, effects,
broadcasts, and dead letters. Reusing the logical identity creates a new
instance primary key with fresh state and message sequence.

Indexes:

- unique identity: enforces one logical actor;
- lease expiration/last claim/ID: operational lease scans and cleanup;
- owner: dead-process cleanup;
- last used/ID: retention and reconciliation.

Instance expiration is disabled unless its actor type has an explicit
retention policy. The pruner uses the last-used index for candidate discovery,
then locks and rechecks that the actor has no owner, mailbox membership,
scheduled reminder, unresolved outbox, or dead letter before deletion.

### `messages`

Durable immutable invocation identity and arguments plus sequence, attempt
count, request/idempotency IDs, result/error, requested availability, and
execution timestamps. A terminal domain rejection stores a structured
code/message/details document and rejection time. The table intentionally has
no status column.

Indexes:

- unique instance/sequence and actor identity/sequence: mailbox order;
- unique request ID: synchronous result lookup;
- unique instance/idempotency key: deduplicated enqueue;
- completion/ID: bounded retention cleanup;
- rejection/ID: bounded rejection inspection and cleanup.

### `ready_messages`

Small hot membership table for due or future work. A row exists only while its
message is ready.

Indexes:

- unique message ID;
- unique instance/sequence;
- availability/instance/sequence polling index.

### `claimed_messages`

Small hot membership table for one message currently owned by an activation.
It records process UUID, unique activation token, activation generation, and
claim time.

Indexes:

- unique message ID;
- unique instance ID, enforcing at most one claimed turn for an actor;
- process/claim time for crash cleanup.

### `reminders`

Durable one-shot or recurring alarm definitions. Unique instance/name makes
rescheduling an actor-owned reminder deterministic. Status/next-run/ID drives
the due scan. Claim ownership references the process registry, and constraints
limit recurrence intervals, missed-work policies, and statuses.

### `effects`

Transactional external-effect outbox. It stores stable effect UUID, arguments,
optional actor outcome messages, attempts, claim ownership, result/error, and
completion time. Claim ownership references the process registry.
Status/availability/ID drives delivery; completion/ID drives cleanup.

### `broadcasts`

Durable observable-change outbox. The unique message/observable key prevents
duplicate rows for one actor turn. Claim and delivery indexes support retries
and cleanup.

### `dead_letters`

Permanent message failures with original identity/arguments, attempts,
exception summary, bounded backtrace, failure times, and optional retried
message ID.

### `processes`

Worker/effect/reminder/broadcast process UUID, kind, hostname, PID, start and
heartbeat times, metadata, graceful shutdown state, and stop times.

## JSON types

PostgreSQL uses JSONB. MySQL uses native JSON. SQLite uses Active Record's JSON
type. Ruby `Marshal` is never used.

## Why membership tables

Completed messages remain useful history, but they never occupy the polling
index. Moving a message between ready and claimed tables makes executable state
physical table membership. The hot indexes stay proportional to live work,
avoid backend-specific partial indexes, and are portable across all supported
databases.

## Cascading destruction

The public `reference.destroy` operation locks the instance row before deleting
it. Every actor-owned table has a cascading foreign key either directly to the
instance or through its message row. No application-side bulk delete can leave
an executable orphan. Process registry rows are not actor-owned and remain
available for worker lifecycle accounting. Activation-owner foreign keys use
restrictive deletion so the owner/token check remains enforceable on MySQL;
runtime deregistration clears leases and claims before a process row can be
pruned.
