# rbs_inline: enabled

module SolidObjects
  class Activation
    # @rbs @lease: Lease
    # @rbs @actor_class: Class
    # @rbs @actor: Actor
    # @rbs @last_used_at: Float
    # @rbs @pass_exhausted: bool

    attr_reader :lease, :actor

    # @rbs (lease: Lease) -> void
    def initialize(lease:)
      @lease = lease
      instance = Instance.find(lease.instance_id)
      @actor_class = SolidObjects.registry.fetch(instance.actor_type)
      @actor = build_actor(instance)
      @last_used_at = monotonic_now
      @pass_exhausted = false
      actor.activate
      SolidObjects.instrument(
        :"activation.started",
        instance_id: instance.id,
        actor_type: instance.actor_type,
        actor_id: instance.actor_id,
        owner_id: lease.owner_id,
        generation: lease.generation
      )
    end

    # @rbs () -> Integer
    def drain
      processed_count = 0
      started_at = monotonic_now
      @pass_exhausted = false

      loop do
        if processed_count >= SolidObjects.configuration.max_messages_per_activation_pass ||
            monotonic_now - started_at >= SolidObjects.configuration.max_activation_duration
          @pass_exhausted = true
          break
        end

        message = claim_next_message
        break unless message

        Executor.new(activation: self, message:).call
        processed_count += 1
        @last_used_at = monotonic_now
      end

      processed_count
    end

    # @rbs () -> bool
    def ready?
      now = SolidObjects.database_adapter.database_now
      ReadyMessage.where(instance_id: lease.instance_id, available_at: ..now).exists? ||
        ClaimedMessage.where(
          instance_id: lease.instance_id,
          process_id: lease.owner_id,
          activation_generation: lease.generation
        ).exists?
    end

    # @rbs () -> bool
    def pass_exhausted?
      @pass_exhausted
    end

    # @rbs () -> bool
    def idle?
      monotonic_now - @last_used_at >= SolidObjects.configuration.idle_deactivation_timeout
    end

    # @rbs () -> void
    def renew_lease
      @lease = lease.renew
    end

    # @rbs () -> bool
    def lease_renewal_due?
      lease.expires_at - SolidObjects.database_adapter.database_now <=
        SolidObjects.configuration.lease_renewal_interval
    end

    # @rbs () -> void
    def yield_ready_messages
      now = SolidObjects.database_adapter.database_now
      ReadyMessage
        .where(instance_id: lease.instance_id, available_at: ..now)
        .update_all(available_at: now)
    end

    # @rbs (Hash[String, untyped]) -> void
    def restore_state(state_data)
      @actor = actor_class.new(
        actor_id: actor.actor_id,
        state: State.new(actor_class.definition.state_definition, state_data)
      )
    end

    # @rbs () -> void
    def deactivate
      actor.deactivate
      lease.release
    rescue LostActivation
      nil
    end

    private

    attr_reader :actor_class

    # @rbs (Instance) -> Actor
    def build_actor(instance)
      state_data = actor_class.definition.migrate_state(instance.state_version, instance.state)
      actor_class.new(
        actor_id: instance.actor_id,
        state: State.new(actor_class.definition.state_definition, state_data)
      )
    end

    # @rbs () -> Message?
    def claim_next_message
      lease.fenced_transaction do |instance|
        recover_stale_claim(instance)
        ready_message = ReadyMessage
          .where(instance_id: instance.id)
          .order(:sequence)
          .first
        next unless ready_message

        now = SolidObjects.database_adapter.database_now
        next if ready_message.available_at > now

        message = Message.lock.find(ready_message.message_id)
        ready_message.destroy!
        message.update!(
          attempt_count: message.attempt_count + 1,
          started_at: now
        )
        ClaimedMessage.create!(
          message:,
          instance:,
          process_id: lease.owner_id,
          activation_generation: lease.generation,
          claimed_at: now
        )
        message
      end
    end

    # @rbs (Instance) -> void
    def recover_stale_claim(instance)
      claimed_message = ClaimedMessage
        .joins(:message)
        .where(instance_id: instance.id)
        .order("#{Message.table_name}.sequence")
        .first
      return unless claimed_message
      return if claimed_message.process_id == lease.owner_id &&
        claimed_message.activation_generation == lease.generation

      message = claimed_message.message
      claimed_message.destroy!
      return if message.completed? || message.dead?

      ReadyMessage.create!(
        message:,
        instance:,
        sequence: message.sequence,
        available_at: SolidObjects.database_adapter.database_now
      )
    end

    # @rbs () -> Float
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
