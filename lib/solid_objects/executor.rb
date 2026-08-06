# rbs_inline: enabled

module SolidObjects
  class Executor
    # @rbs @activation: Activation
    # @rbs @message: Message

    # @rbs (activation: Activation, message: Message) -> void
    def initialize(activation:, message:)
      @activation = activation
      @message = message
    end

    # @rbs () -> bool
    def call
      state_before = actor.state.to_h
      observables_before = actor.observable_values
      message_context = MessageContext.new(
        id: message.id,
        attempt: message.attempt_count,
        enqueued_at: message.enqueued_at,
        idempotency_key: message.idempotency_key,
        request_id: message.request_id
      )

      SolidObjects.instrument(:"message.started", **instrumentation_payload)
      result = invoke_actor(message_context)
      ensure_query_did_not_mutate_state!(state_before)
      observable_changes = changed_observables(observables_before, actor.observable_values)
      complete(result, observable_changes)
      true
    rescue LostActivation
      raise
    rescue Rejected => rejection
      activation.restore_state(state_before) if state_before
      actor.discard_intents
      reject_message(rejection)
      false
    rescue => error
      activation.restore_state(state_before) if state_before
      actor.discard_intents
      fail_message(error)
      false
    end

    private

    attr_reader :activation, :message

    # @rbs () -> Actor
    def actor
      activation.actor
    end

    # @rbs (MessageContext) -> untyped
    def invoke_actor(message_context)
      Context.with(actor:, message: message_context) do
        actor.invoke(message.message_name, message.arguments)
      end
    end

    # @rbs (Hash[String, untyped]) -> void
    def ensure_query_did_not_mutate_state!(state_before)
      return unless message.message_kind == "sync"
      return unless actor.class.definition.queries.key?(message.message_name.to_sym)
      return if actor.state.to_h == state_before

      raise InvalidActor, "query #{message.message_name.inspect} mutated actor state"
    end

    # @rbs (Hash[String, untyped], Hash[String, untyped]) -> Hash[String, untyped]
    def changed_observables(before, after)
      after.each_with_object({}) do |(name, value), changes|
        changes[name] = value unless before[name] == value
      end
    end

    # @rbs (untyped, Hash[String, untyped]) -> void
    def complete(result, observable_changes)
      serialized_state = Serialization.dump(
        actor.state.to_h,
        max_bytes: SolidObjects.configuration.max_state_bytes
      )
      serialized_result = Serialization.dump(
        (message.message_kind == "sync") ? result : nil,
        max_bytes: SolidObjects.configuration.max_result_bytes
      )
      effect_intents = actor.drain_effect_intents
      commit_action_intents = actor.drain_commit_action_intents
      reminder_intents = actor.drain_reminder_intents
      outbound_message_intents = actor.drain_outbound_message_intents
      enqueued_effects = []

      activation.lease.fenced_transaction do |instance|
        claimed_message = matching_claim!
        locked_message = Message.lock.find(message.id)
        execute_commit_actions(commit_action_intents)
        instance.update!(
          state: serialized_state,
          state_version: actor.class.state_version,
          last_used_at: SolidObjects.database_adapter.database_now
        )
        locked_message.update!(
          result: serialized_result,
          error: nil,
          completed_at: SolidObjects.database_adapter.database_now
        )
        enqueued_effects.concat(enqueue_effects(locked_message, instance, effect_intents))
        schedule_reminders(instance, reminder_intents)
        enqueued_effects.concat(
          enqueue_actor_messages(locked_message, instance, outbound_message_intents)
        )
        enqueue_broadcasts(locked_message, instance, observable_changes)
        claimed_message.destroy!
      end

      observable_changes.each_key do |observable_name|
        SolidObjects.instrument(
          :"broadcast.enqueued",
          **instrumentation_payload,
          observable_name:
        )
      end
      enqueued_effects.each do |effect|
        SolidObjects.instrument(
          :"effect.enqueued",
          effect_id: effect.effect_id,
          effect_name: effect.name,
          message_id: effect.message_id,
          actor_type: message.actor_type,
          actor_id: message.actor_id
        )
      end
      SolidObjects.instrument(:"message.completed", **instrumentation_payload)
      SolidObjects.wake_up.signal
    end

    # @rbs (Array[Actor::CommitActionIntent]) -> void
    def execute_commit_actions(intents)
      ensure_application_database_is_shared! if intents.any?
      context = CommitActionContext.new(
        message_id: message.id,
        request_id: message.request_id,
        actor_type: message.actor_type,
        actor_id: message.actor_id,
        activation_generation: activation.lease.generation
      )

      intents.each do |intent|
        handler = SolidObjects.commit_action_registry.fetch(intent.name)
        execute_commit_action(intent, handler, context)
      end
    end

    # @rbs (Actor::CommitActionIntent, Proc, CommitActionContext) -> untyped
    def execute_commit_action(intent, handler, context)
      payload = {
        commit_action_name: intent.name,
        message_id: message.id,
        request_id: message.request_id,
        actor_type: message.actor_type,
        actor_id: message.actor_id,
        activation_generation: activation.lease.generation
      }
      SolidObjects.instrument(:"commit_action.started", **payload)
      handler.call(intent.arguments, context).tap do
        SolidObjects.instrument(:"commit_action.completed", **payload)
      end
    rescue => error
      SolidObjects.instrument(
        :"commit_action.failed",
        **payload,
        error_class: error.class.name,
        error_message: error.message
      )
      raise
    end

    # @rbs () -> void
    def ensure_application_database_is_shared!
      return if SolidObjects::Record.connection_pool.equal?(ActiveRecord::Base.connection_pool)

      raise CommitActionUnavailable.new(
        actor_type: message.actor_type,
        actor_id: message.actor_id,
        message_name: message.message_name
      )
    end

    # @rbs (Message, Instance, Array[Actor::EffectIntent]) -> Array[Effect]
    def enqueue_effects(locked_message, instance, intents)
      intents.map do |intent|
        Effect.create!(
          message: locked_message,
          instance:,
          effect_id: SecureRandom.uuid,
          name: intent.name,
          arguments: intent.arguments,
          success_message_name: intent.success_message_name,
          failure_message_name: intent.failure_message_name,
          status: "pending",
          max_attempts: SolidObjects.configuration.max_attempts,
          available_at: SolidObjects.database_adapter.database_now
        )
      end
    end

    # @rbs (Instance, Array[Actor::ReminderIntent]) -> void
    def schedule_reminders(instance, intents)
      intents.each do |intent|
        reminder = Reminder.find_or_initialize_by(instance:, name: intent.name)
        reminder.assign_attributes(
          actor_type: instance.actor_type,
          actor_id: instance.actor_id,
          message_name: intent.name,
          arguments: intent.arguments,
          next_run_at: intent.at,
          interval_seconds: intent.interval_seconds,
          missed_policy: intent.missed_policy,
          status: "scheduled",
          claimed_by: nil,
          claimed_at: nil
        )
        reminder.save!
      end
    end

    # @rbs (Message, Instance, Array[Actor::OutboundMessageIntent]) -> Array[Effect]
    def enqueue_actor_messages(locked_message, instance, intents)
      intents.map do |intent|
        Effect.create!(
          message: locked_message,
          instance:,
          effect_id: SecureRandom.uuid,
          name: EffectExecutor::ACTOR_MESSAGE_EFFECT,
          arguments: {
            "actor_type" => intent.actor_type,
            "actor_id" => intent.actor_id,
            "message_name" => intent.message_name,
            "arguments" => intent.arguments,
            "available_at" => intent.available_at&.iso8601(6),
            "idempotency_key" => intent.idempotency_key
          },
          status: "pending",
          max_attempts: SolidObjects.configuration.max_attempts,
          available_at: SolidObjects.database_adapter.database_now
        )
      end
    end

    # @rbs (Message, Instance, Hash[String, untyped]) -> void
    def enqueue_broadcasts(locked_message, instance, observable_changes)
      observable_changes.each do |observable_name, value|
        Broadcast.create!(
          message: locked_message,
          instance:,
          broadcast_id: SecureRandom.uuid,
          observable_name:,
          value:,
          state_version: actor.class.state_version,
          activation_generation: activation.lease.generation,
          status: "pending",
          available_at: SolidObjects.database_adapter.database_now
        )
      end
    end

    # @rbs (Exception) -> void
    def fail_message(error)
      error_details = serialized_error(error)
      dead = false

      activation.lease.fenced_transaction do
        claimed_message = matching_claim!
        locked_message = Message.lock.find(message.id)
        now = SolidObjects.database_adapter.database_now
        locked_message.update!(error: error_details, last_failed_at: now)
        claimed_message.destroy!

        if error.is_a?(NonRetryableError) ||
            locked_message.attempt_count >= locked_message.max_attempts
          create_dead_letter(locked_message, error_details, now)
          dead = true
        else
          ReadyMessage.create!(
            message: locked_message,
            instance: locked_message.instance,
            sequence: locked_message.sequence,
            available_at: now + SolidObjects.configuration.retry_delay.call(locked_message.attempt_count)
          )
        end
      end

      SolidObjects.instrument(
        :"message.failed",
        **instrumentation_payload,
        error_class: error.class.name,
        dead:
      )
      SolidObjects.wake_up.signal
    end

    # @rbs (Rejected) -> void
    def reject_message(rejection)
      rejection_data = Serialization.dump(
        {
          "code" => rejection.code,
          "message" => rejection.message.to_s.byteslice(0, 8_192),
          "details" => rejection.details
        },
        max_bytes: SolidObjects.configuration.max_result_bytes
      )

      activation.lease.fenced_transaction do |instance|
        claimed_message = matching_claim!
        locked_message = Message.lock.find(message.id)
        now = SolidObjects.database_adapter.database_now
        instance.update!(last_used_at: now)
        locked_message.update!(
          result: nil,
          rejection: rejection_data,
          error: nil,
          rejected_at: now,
          completed_at: now
        )
        claimed_message.destroy!
      end

      SolidObjects.instrument(
        :"message.rejected",
        **instrumentation_payload,
        code: rejection.code
      )
      SolidObjects.wake_up.signal
    end

    # @rbs () -> ClaimedMessage
    def matching_claim!
      ClaimedMessage.lock.find_by!(
        message_id: message.id,
        process_id: activation.lease.owner_id,
        activation_token: activation.lease.activation_token,
        activation_generation: activation.lease.generation
      )
    rescue ActiveRecord::RecordNotFound
      raise LostActivation, "message claim changed"
    end

    # @rbs (Exception) -> Hash[String, untyped]
    def serialized_error(error)
      Serialization.dump(
        {
          "class" => error.class.name,
          "message" => error.message.to_s.byteslice(0, 8_192),
          "backtrace" => Array(error.backtrace).first(50)
        }
      )
    end

    # @rbs (Message, Hash[String, untyped], Time) -> DeadLetter
    def create_dead_letter(locked_message, error_details, now)
      DeadLetter.create!(
        message: locked_message,
        instance: locked_message.instance,
        actor_type: locked_message.actor_type,
        actor_id: locked_message.actor_id,
        message_name: locked_message.message_name,
        arguments: locked_message.arguments,
        attempts: locked_message.attempt_count,
        exception_class: error_details.fetch("class"),
        exception_message: error_details.fetch("message"),
        backtrace: error_details.fetch("backtrace"),
        first_failed_at: locked_message.last_failed_at || now,
        last_failed_at: now
      )
    end

    # @rbs () -> Hash[Symbol, untyped]
    def instrumentation_payload
      {
        message_id: message.id,
        actor_type: message.actor_type,
        actor_id: message.actor_id,
        sequence: message.sequence,
        attempt: message.attempt_count,
        request_id: message.request_id
      }
    end
  end
end
