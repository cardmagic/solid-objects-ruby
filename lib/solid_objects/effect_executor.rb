# rbs_inline: enabled

module SolidObjects
  EffectContext = Data.define(:id, :attempt, :source_message_id, :actor_type, :actor_id)

  class EffectExecutor
    ACTOR_MESSAGE_EFFECT = "__actor_message__"

    # @rbs @process_registry: ProcessRegistry
    # @rbs @database_adapter: DatabaseAdapter
    # @rbs @stopped: bool
    # @rbs @shutdown_requested: bool

    # @rbs (?process_registry: ProcessRegistry, ?database_adapter: DatabaseAdapter) -> void
    def initialize(
      process_registry: ProcessRegistry.new,
      database_adapter: SolidObjects.database_adapter
    )
      @process_registry = process_registry
      @database_adapter = database_adapter
      process_registry.register(kind: "effect")
      @stopped = false
      @shutdown_requested = false
    end

    # @rbs () -> bool
    def run_once
      return false if stopped?

      process_registry.heartbeat
      effect = claim_next
      return false unless effect

      result = deliver(effect)
      complete(effect, result)
      true
    rescue => error
      fail_effect(effect, error) if effect
      false
    end

    # @rbs () -> void
    def stop
      return if stopped?

      @stopped = true
      process_registry.start_draining
      process_registry.stop
    end

    # @rbs () -> void
    def run
      until shutdown_requested?
        worked = run_once
        next if worked

        SolidObjects.wake_up.wait(timeout: SolidObjects.configuration.polling_interval)
      end
    ensure
      stop
    end

    # @rbs () -> void
    def request_shutdown
      @shutdown_requested = true
      SolidObjects.wake_up.signal
    end

    # @rbs () -> bool
    def stopped?
      @stopped
    end

    # @rbs () -> bool
    def shutdown_requested?
      @shutdown_requested
    end

    private

    attr_reader :process_registry, :database_adapter

    # @rbs () -> Effect?
    def claim_next
      database_adapter.transaction do
        now = database_adapter.database_now
        effect = database_adapter.lock_candidates(
          Effect.where(status: "pending", available_at: ..now).order(:available_at, :id)
        ).first
        next unless effect

        effect.update!(
          status: "processing",
          attempt_count: effect.attempt_count + 1,
          claimed_by: process_registry.process_record.id,
          claimed_at: now
        )
        effect
      end
    end

    # @rbs (Effect) -> untyped
    def deliver(effect)
      return deliver_actor_message(effect) if effect.name == ACTOR_MESSAGE_EFFECT

      handler = SolidObjects.effect_registry.fetch(effect.name)
      context = EffectContext.new(
        id: effect.effect_id,
        attempt: effect.attempt_count,
        source_message_id: effect.message_id,
        actor_type: effect.instance.actor_type,
        actor_id: effect.instance.actor_id
      )
      handler.call(effect.arguments, context)
    end

    # @rbs (Effect) -> Integer
    def deliver_actor_message(effect)
      arguments = effect.arguments
      reference = Reference.new(
        actor_type: arguments.fetch("actor_type"),
        actor_id: arguments.fetch("actor_id")
      )
      actor_class = SolidObjects.registry.fetch(reference.actor_type)
      operation = arguments.fetch("operation")
      unless actor_class.definition.messages.key?(operation.to_sym)
        raise UnknownMessage, "unknown actor-to-actor operation #{operation.inspect}"
      end

      available_at = arguments["available_at"]
      available_at = Time.iso8601(available_at) if available_at
      Mailbox.new.enqueue(
        reference:,
        operation:,
        arguments: arguments.fetch("arguments"),
        delivery_mode: "internal",
        available_at:,
        idempotency_key: effect.effect_id
      ).id
    end

    # @rbs (Effect, untyped) -> void
    def complete(effect, result)
      serialized_result = Serialization.dump(
        result,
        max_bytes: SolidObjects.configuration.max_result_bytes
      )
      result_message = nil
      database_adapter.transaction do
        locked_effect = Effect.lock.find(effect.id)
        verify_claim!(locked_effect)
        result_message = enqueue_result_message(
          effect: locked_effect,
          operation: locked_effect.success_operation,
          outcome: "success",
          arguments: {
            "effect_id" => locked_effect.effect_id,
            "arguments" => locked_effect.arguments,
            "result" => serialized_result
          }
        )
        locked_effect.update!(
          status: "completed",
          result: serialized_result,
          error: nil,
          completed_at: database_adapter.database_now,
          claimed_by: nil,
          claimed_at: nil
        )
      end
      Mailbox.new.announce(result_message) if result_message
      SolidObjects.instrument(
        :"effect.completed",
        effect_id: effect.effect_id,
        effect_name: effect.name,
        message_id: effect.message_id,
        attempt: effect.attempt_count
      )
    end

    # @rbs (Effect, Exception) -> void
    def fail_effect(effect, error)
      result_message = nil
      database_adapter.transaction do
        locked_effect = Effect.lock.find(effect.id)
        verify_claim!(locked_effect)
        dead = locked_effect.attempt_count >= locked_effect.max_attempts
        error_details = {
          "class" => error.class.name,
          "message" => error.message.to_s.byteslice(0, 8_192),
          "backtrace" => Array(error.backtrace).first(50)
        }
        if dead
          result_message = enqueue_result_message(
            effect: locked_effect,
            operation: locked_effect.failure_operation,
            outcome: "failure",
            arguments: {
              "effect_id" => locked_effect.effect_id,
              "arguments" => locked_effect.arguments,
              "error" => error_details
            }
          )
        end
        locked_effect.update!(
          status: dead ? "dead" : "pending",
          available_at: database_adapter.database_now +
            SolidObjects.configuration.retry_delay.call(locked_effect.attempt_count),
          error: error_details,
          claimed_by: nil,
          claimed_at: nil
        )
      end
      Mailbox.new.announce(result_message) if result_message
    rescue ActiveRecord::RecordNotFound, LostActivation
      nil
    end

    # @rbs (Effect) -> void
    def verify_claim!(effect)
      return if effect.status == "processing" &&
        effect.claimed_by == process_registry.process_record.id

      raise LostActivation, "effect claim changed"
    end

    # @rbs (effect: Effect, operation: String?, outcome: String, arguments: Hash[String, untyped]) -> Message?
    def enqueue_result_message(effect:, operation:, outcome:, arguments:)
      return unless operation

      Mailbox.new.enqueue_in_transaction(
        reference: Reference.new(
          actor_type: effect.instance.actor_type,
          actor_id: effect.instance.actor_id
        ),
        operation:,
        arguments:,
        delivery_mode: "internal",
        idempotency_key: "effect:#{effect.effect_id}:#{outcome}"
      )
    end
  end
end
