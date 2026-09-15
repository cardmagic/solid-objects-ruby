# rbs_inline: enabled

module SolidObjects
  module EffectRecoveryOutcome
    RETIRED = "retired".freeze #: "retired"
    DEFERRED = "deferred".freeze #: "deferred"
    PENDING = "pending".freeze #: "pending"
    COMPLETED = "completed".freeze #: "completed"
    DEAD = "dead".freeze #: "dead"
    ALREADY_RETIRED = "already_retired".freeze #: "already_retired"
    MISSING = "missing".freeze #: "missing"
  end

  class EffectRecoveryCoordinator
    # @rbs (instance: Instance, intents: Array[Actor::EffectRecoveryIntent]) -> void
    def check(instance:, intents:)
      return if intents.empty?

      effect_ids = intents.map(&:effect_id).uniq.sort
      effects = Effect.where(instance_id: instance.id, effect_id: effect_ids).order(:effect_id).lock.to_a.index_by(&:effect_id)
      recoveries = EffectRecovery.where(instance_id: instance.id, effect_id: effect_ids).order(:effect_id).lock.to_a.index_by(&:effect_id)
      effect_ids.each do |effect_id|
        recovery = recoveries[effect_id]
        unless recovery&.recovery_operation && recovery.status_operation
          raise InvalidPayload, "effect recovery requires an owned handle with on_recovery and on_status"
        end
      end
      owner_ids = effects.values.filter_map(&:claimed_by).uniq.sort
      owners = Process.where(id: owner_ids).order(:id).lock.to_a.index_by(&:id)
      now = SolidObjects.database_adapter.database_clock_now
      intents.each do |intent|
        check_one(instance:, intent:, recovery: recoveries.fetch(intent.effect_id), effect: effects[intent.effect_id], owners:, now:)
      end
    end

    # @rbs () -> void
    def recover_available
      candidates = EffectRecovery.where(retired_at: nil).where.not(recovery_operation: nil)
        .where(effect_id: Effect.where(status: "processing").select(:effect_id))
      candidates.find_each do |candidate|
        notification = SolidObjects.database_adapter.transaction do
          instance = Instance.lock.find_by(id: candidate.instance_id)
          next unless instance

          effect = Effect.lock.find_by(effect_id: candidate.effect_id, instance_id: instance.id)
          recovery = EffectRecovery.lock.find_by(effect_id: candidate.effect_id, instance_id: instance.id)
          next unless effect && recovery
          next if recovery.retired_at || effect.status != "processing"

          owner = Process.lock.find_by(id: effect.claimed_by) if effect.claimed_by
          now = SolidObjects.database_adapter.database_clock_now
          timeout = [ SolidObjects.configuration.process_alive_threshold, recovery.recovery_timeout || 0 ].max
          next if owner && owner.last_heartbeat_at > now - timeout

          retire(instance:, effect:, recovery:, now:)
        end
        Mailbox.new.announce(notification) if notification
      end
    end

    private

    # @rbs (instance: Instance, intent: Actor::EffectRecoveryIntent, recovery: EffectRecovery, effect: Effect?, owners: Hash[String, Process], now: Time) -> void
    def check_one(instance:, intent:, recovery:, effect:, owners:, now:)
      key = "effect:#{intent.effect_id}:check:#{intent.request_id}"
      return if Message.where(instance_id: instance.id, idempotency_key: key).exists?

      outcome = observe(effect:, recovery:, owners:, now:)
      retire(instance:, effect:, recovery:, now:) if outcome == EffectRecoveryOutcome::RETIRED
      operation = recovery.status_operation
      unless operation && SolidObjects.registry.fetch(instance.actor_type).definition.messages.key?(operation.to_sym)
        raise UnknownMessage, "unknown effect status operation #{operation.inspect}"
      end
      arguments = case outcome
      when EffectRecoveryOutcome::RETIRED
        EffectPayload.retired(effect_id: intent.effect_id, arguments: effect.arguments)
      when EffectRecoveryOutcome::COMPLETED
        EffectPayload.recovery_completed(effect_id: intent.effect_id, arguments: effect.arguments, result: effect.result)
      else
        EffectPayload.recovery_observation(effect_id: intent.effect_id, outcome:)
      end
      Mailbox.new.enqueue_in_transaction(
        reference: Reference.new(actor_type: instance.actor_type, actor_id: instance.actor_id),
        operation:,
        arguments:,
        delivery_mode: "internal",
        idempotency_key: key
      )
    end

    # @rbs (effect: Effect?, recovery: EffectRecovery, owners: Hash[String, Process], now: Time) -> String
    def observe(effect:, recovery:, owners:, now:)
      return EffectRecoveryOutcome::ALREADY_RETIRED if recovery.retired_at
      return EffectRecoveryOutcome::MISSING unless effect
      return EffectRecoveryOutcome::PENDING if effect.status == "pending"
      return EffectRecoveryOutcome::COMPLETED if effect.status == "completed"
      return EffectRecoveryOutcome::DEAD if effect.status == "dead"

      owner = owners[effect.claimed_by]
      timeout = [ SolidObjects.configuration.process_alive_threshold, recovery.recovery_timeout || 0 ].max
      return EffectRecoveryOutcome::DEFERRED if owner && owner.last_heartbeat_at > now - timeout

      EffectRecoveryOutcome::RETIRED
    end

    # @rbs (instance: Instance, effect: Effect, recovery: EffectRecovery, now: Time) -> Message
    def retire(instance:, effect:, recovery:, now:)
      actor_class = SolidObjects.registry.fetch(instance.actor_type)
      operation = recovery.recovery_operation
      unless operation && actor_class.definition.messages.key?(operation.to_sym)
        raise UnknownMessage, "unknown effect recovery operation #{operation.inspect}"
      end

      effect.update!(status: "completed", completed_at: now, claimed_by: nil, claimed_at: nil)
      recovery.update!(retired_at: now)
      Mailbox.new.enqueue_in_transaction(
        reference: Reference.new(actor_type: instance.actor_type, actor_id: instance.actor_id),
        operation:,
        arguments: EffectPayload.retired(effect_id: effect.effect_id, arguments: effect.arguments),
        delivery_mode: "internal",
        idempotency_key: "effect:#{effect.effect_id}:recovery"
      )
    end
  end
end
