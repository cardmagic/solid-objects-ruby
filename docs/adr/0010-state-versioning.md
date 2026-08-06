# ADR 0010: Explicit Actor State Versions

- Status: Accepted
- Date: 2026-08-05

## Context

Persistent actors can outlive application releases. During a rolling deployment, old and new worker processes can briefly execute different actor code.

## Decision

Every actor class declares a current integer state version. Migrations must form an unbroken, one-step chain from stored version to current version. The runtime must refuse to activate an actor whose stored state version is newer than the actor class declares.

Process metadata includes an application/runtime version. Deployments that change state shape must keep old code able to read the new representation or drain old workers before new-version messages can commit. Automatic downgrade is unsupported.

Operating rules are normative:

- Additive, backward-readable state changes do not require a version bump.
- Destructive or reinterpretive changes use an expand/contract deployment across at least two releases.
- A new migration may run only while every live worker can read the resulting representation, or after incompatible workers are drained.
- Actor state migrations are permanent history. They cannot be squashed like Rails schema migrations because an actor may reactivate from a blob written years earlier.

## Consequences

- Rolling safety is an application responsibility and is never hidden.
- Additive, backward-readable changes are preferred.
- Destructive migrations require a coordinated drain or two-phase deployment.
- Published migration steps remain in the actor code or an equivalent archival migration registry.
- Migration errors fail the message without modifying stored state.
