# Effect recovery coordination

`emit` returns a JSON-serializable handle containing the public `effect_id`.
Registering `on_recovery` opts the effect into retirement when its owner has
stopped heartbeating. `on_status` is optional and receives responses only to
explicit `request_effect_recovery(handle)` intents. Normal success and failure
retain their existing callbacks.

## Watchdog using supported APIs

```ruby
class ReportExport < SolidObjects::Actor
  attribute :revision, default: 0
  attribute :export_effect, default: nil
  attribute :artifact_key, default: ""
  attribute :applied_effect_id, default: nil

  def start
    self.revision += 1
    self.export_effect = emit(:build_report,
      revision: revision,
      on_success: :export_finished,
      on_failure: :export_failed,
      on_recovery: :recover_export,
      on_status: :inspect_export,
      recovery_timeout: 120)
    schedule(at: Time.now + 30, key: "export-watchdog").watchdog
    nil
  end

  def watchdog
    request_effect_recovery(export_effect) if export_effect
  end

  def recover_export(effect_id:, arguments:, outcome:)
    return unless effect_id == export_effect&.fetch("effect_id")
    return unless arguments.fetch("revision") == revision

    start
  end

  def export_finished(effect_id:, arguments:, result:)
    apply_export_result(effect_id:, arguments:, result:)
  end

  def export_failed(effect_id:, arguments:, error:)
  end

  def inspect_export(effect_id:, outcome:, arguments: nil, result: nil)
    return unless effect_id == export_effect&.fetch("effect_id")

    case outcome
    when SolidObjects::EffectRecoveryOutcome::COMPLETED
      apply_export_result(effect_id:, arguments:, result:)
    when SolidObjects::EffectRecoveryOutcome::DEFERRED, SolidObjects::EffectRecoveryOutcome::PENDING
      schedule(at: Time.now + 30, key: "export-watchdog").watchdog
    end
  end

  private

  def apply_export_result(effect_id:, arguments:, result:)
    return unless effect_id == export_effect&.fetch("effect_id")
    return unless arguments.fetch("revision") == revision
    return if applied_effect_id == effect_id

    self.artifact_key = result.fetch("artifact_key")
    self.applied_effect_id = effect_id
  end
end
```

Register `build_report` through the ordinary effect registry. Its successful
result in this example is `{ "artifact_key" => "reports/example.pdf" }`.
The library builds the retirement payload, including `"outcome" => "retired"`;
the effect handler does not return that outcome itself. Ruby actor operations
receive keywords. `recover_export` needs handle/revision guards but no outcome
guard because only a new retirement invokes it. The same guarded result helper
handles success and completed-status repair, preventing duplicate application.
Only recovery emits a replacement; status observations never do.

The watchdog is optional: `on_recovery` alone enables automatic retirement.
`on_status` alone does not enable retirement, polling, or subscriptions. Explicit
checks require both bindings persisted by `emit` and cannot replace either.

## Public envelopes and timeout

`SolidObjects::effect_handle` describes `{ "effect_id" => String }`.
`SolidObjects::effect_retired_payload[Arguments]` requires the effect ID, original
arguments, and `"outcome" => "retired"`. Status uses
`SolidObjects::effect_recovery_payload[Arguments, Result]`, a record union.
Every variant has an effect ID; retired and completed require original arguments;
only completed has a recorded result (including `nil`). Other Ruby observations
contain only the effect ID and outcome.

Strict packaged-consumer tests verify the constant literals and individual
records. Steep 2.0 does not narrow this string-keyed record union after comparing
`payload["outcome"]` with `COMPLETED`; accessing `result` through the union still
fails its return-type check. Use the concrete completed/retired record in typed
helpers after validating the discriminator, with an explicit type assertion if
needed. The library retains precise records rather than weakening them to an
untyped hash. Ordinary Ruby keyword dispatch needs no payload hydration.

| Frozen `SolidObjects::EffectRecoveryOutcome` constant | Wire value | Meaning |
| --- | --- | --- |
| `RETIRED` | `"retired"` | This check retired the effect; separate recovery owns replacement. |
| `DEFERRED` | `"deferred"` | Fresh owner; preserve its claim and attempts. |
| `PENDING` | `"pending"` | Initial execution or retry remains with the scheduler. |
| `COMPLETED` | `"completed"` | Original arguments and recorded result are available. |
| `DEAD` | `"dead"` | Preserve terminal failure and its existing callback. |
| `ALREADY_RETIRED` | `"already_retired"` | Earlier retirement; no additional recovery notification. |
| `MISSING` | `"missing"` | Owned binding exists but effect data was pruned. |

`recovery_timeout` must be positive finite seconds and requires `on_recovery`.
Fractional durations are allowed. Omission uses the current runtime
`process_alive_threshold`, normally 60 seconds. Smaller positive values are
floored at that runtime threshold; changing configuration changes the effective
floor even for existing effects. Database lookup errors surface as errors,
never as missing/stale observations.

Effect workers maintain their process heartbeat while the handler waits on
external I/O and while committing success or failure. A long-running healthy
handler therefore remains protected beyond the recovery timeout. This requires
an available database connection for the heartbeat, as well as runtime threads
that can continue running.

## Compatibility and installation

Upgrade all effect workers and process cleanup roles before emitting effects
with recovery enabled. Older runtimes do not honor the persisted bindings or
the new lock protocol.

Run `solid_objects:install:migrations` and your application's normal migration
process before starting upgraded workers. The additive migration creates the
durable binding table; it does not change existing effect status constraints.

`emit` now returns its handle, including without recovery options. Callers may
ignore it. Wrappers must return `super`; operations whose last expression used
to be `emit` may now return the handle to callers. End those operations with
`nil` if their previous result must remain unchanged. The return-value change is
intentional and is not strictly backward compatible.

## Transaction and lock protocol

Emission, actor state, the effect, and its recovery binding share the actor's
fenced commit. An explicit check executes on that same connection. Automatic
recovery performs one independent library transaction per candidate, with no
application transaction waiting on a second connection.

The lock order is originating instance, effect rows ordered by public effect
ID, recovery binding rows in the same order, then owner processes ordered by ID.
Completion and failure must acquire the instance before the effect. Pending
claims lock only their effect and do not subsequently acquire an instance lock.
Mailbox insertion reuses the instance lock already held by the decision.
Multiple checks in one actor commit lock all their effects and bindings before
locking any processes. Unlocked candidate reads are hints, never decisions.

Automatic passes prefilter owner freshness and the effective per-effect timeout
using database time, and visit at most `claim_scan_limit` stale candidates. Fresh
actors and owners are not locked, including owners protected by extended grace.
Remaining stale effects are revisited on later polls. Every candidate still
undergoes the authoritative locked recheck, and successful retirement announces
the committed mailbox work through the existing wake-up mechanism.

The decision samples database wall time after obtaining the owner lock. The
effective timeout is the larger of the runtime's `process_alive_threshold` and
the effect's persisted `recovery_timeout`, in seconds. A heartbeat newer than
the cutoff is fresh; equality is stale. A stopped or draining process with
fresh heartbeat evidence still protects an opted-in effect until that timeout.
Cleanup preserves opted-in claims, and process pruning excludes processes that
still own effects. Later effect polling and process cleanup revisit deferred
effects without resetting their last heartbeat.

Retirement stores a durable `retired_at` in `effect_recoveries` and moves the
effect into the existing terminal `completed` storage state, clearing its
claim. The recovery record distinguishes retirement from successful completion;
no success callback is generated. All recovery observations consult that record
before interpreting the effect row. A late completion or failure is rejected by
the existing processing/claim fence. This representation avoids rewriting the
existing effect-status constraint across adapters.

The retirement record and the recovery mailbox message commit atomically. A
winning explicit check additionally enqueues its status response after the
retirement notification. Failure to insert either message rolls back the whole
decision. Retirement is deduplicated per effect; check responses use separate
per-request idempotency keys. Wake-up signals are delivery hints after commit.

Recovery bindings survive effect/message pruning and remain until the originating
instance is destroyed or pruned. They do not prevent normal message or instance
retention. Within that lifetime, a removed non-retired effect reports `missing`
and a retirement record reports `already_retired`. A handle without an owned
binding raises an error, without disclosing another actor's state or recreating
a destroyed actor. Status-response message idempotency follows normal mailbox
retention; callers cannot supply or reuse internal check request IDs.

An owner heartbeat measures process liveness, not effect progress. Retirement
does not cancel the old handler or prove a remote request stopped. External
actions still require idempotency across retries and replacement generations.
