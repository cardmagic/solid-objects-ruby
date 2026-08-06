# rbs_inline: enabled

require "solid_objects/activation_manager"
require "solid_objects/lease_renewer"

module SolidObjects
  class SynchronousInvocation
    # @rbs (MessageReference, timeout: Numeric) -> untyped
    def call(message_reference, timeout:)
      deadline = monotonic_now + timeout.to_f

      loop do
        message = load_message(message_reference)
        return completed_result(message) if message.completed? || message.dead?

        remaining = deadline - monotonic_now
        unless remaining.positive?
          raise SyncTimeout, "actor invocation timed out after #{timeout} seconds"
        end

        processed = assist(message, deadline:)
        wait(remaining) if processed.zero?
      end
    rescue ActiveRecord::RecordNotFound
      raise ActorDestroyed, "actor was destroyed while waiting for its result"
    end

    private

    # @rbs (MessageReference) -> Message
    def load_message(message_reference)
      Message.uncached { Message.find(message_reference.id) }
    end

    # @rbs (Message) -> untyped
    def completed_result(message)
      raise_rejection(message) if message.rejected?
      if message.dead?
        raise MessageFailed.new(
          "actor message failed permanently",
          message_id: message.id,
          details: message.error || {}
        )
      end

      Serialization.readonly_copy(message.result)
    end

    # @rbs (Message) -> bot
    def raise_rejection(message)
      rejection = message.rejection
      raise Rejected.new(
        code: rejection.fetch("code"),
        message: rejection.fetch("message"),
        details: rejection.fetch("details"),
        message_id: message.id
      )
    end

    # @rbs (Message, deadline: Float) -> Integer
    def assist(message, deadline:)
      process_registry = SolidObjects.caller_process.process_registry
      activation = ActivationManager
        .new(owner_id: process_registry.process_record.id)
        .claim(instance_id: message.instance_id)
      return 0 unless activation

      LeaseRenewer.new(
        activation:,
        process_registry:
      ).around do
        activation.drain_until(message_id: message.id, deadline:)
      end
    ensure
      if activation
        activation.yield_ready_messages if activation.pass_exhausted?
        activation.deactivate
      end
    end

    # @rbs (Numeric) -> void
    def wait(remaining)
      SolidObjects.wake_up.wait(
        timeout: [ remaining, SolidObjects.configuration.sync_polling_interval ].min
      )
    end

    # @rbs () -> Float
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
