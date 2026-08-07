# rbs_inline: enabled

require "solid_objects/activation_manager"
require "solid_objects/lease_renewer"
require "solid_objects/sync_diagnostics"

module SolidObjects
  class SynchronousInvocation
    # @rbs (MessageReference, timeout: Numeric) -> untyped
    def call(message_reference, timeout:)
      return call_before_deadline(message_reference, timeout:) if SyncDeadline.active?

      SyncDeadline.with(timeout:) do
        call_before_deadline(message_reference, timeout:)
      end
    rescue ActiveRecord::RecordNotFound
      raise ActorDestroyed, "actor was destroyed while waiting for its result"
    end

    private

    # @rbs (MessageReference, timeout: Numeric) -> untyped
    def call_before_deadline(message_reference, timeout:)
      deadline = monotonic_now + SyncDeadline.remaining
      message = nil

      loop do
        unless (deadline - monotonic_now).positive?
          final_message = load_message_at_deadline(message_reference)
          return completed_result(final_message) if final_message&.completed? || final_message&.dead?

          raise final_message ?
            diagnose_timeout(final_message, timeout:) :
            contention_timeout(message, message_reference, timeout:)
        end

        message = load_message(message_reference)
        return completed_result(message) if message.completed? || message.dead?

        processed = assist(message, deadline:)
        remaining = deadline - monotonic_now
        wait(remaining) if processed.zero? && remaining.positive?
      end
    rescue DatabaseDeadlineExceeded
      raise message ?
        diagnose_timeout(message, timeout:) :
        contention_timeout(message, message_reference, timeout:)
    end

    # @rbs (MessageReference) -> Message
    def load_message(message_reference)
      SolidObjects.database_adapter.with_lock_retry do
        Message.uncached do
          Message.includes(:dead_letter).find(message_reference.id)
        end
      end
    end

    # @rbs (MessageReference) -> Message?
    def load_message_at_deadline(message_reference)
      SolidObjects.database_adapter.with_lock_probe do
        Message.uncached do
          Message.includes(:dead_letter).find(message_reference.id)
        end
      end
    rescue DatabaseDeadlineExceeded
      nil
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

    # @rbs (Message, timeout: Numeric) -> SyncTimeout
    def diagnose_timeout(message, timeout:)
      SolidObjects.database_adapter.with_lock_probe do
        SyncDiagnostics.new.call(message, timeout:)
      end
    rescue DatabaseDeadlineExceeded
      SyncDiagnostics.new.database_contention(message, timeout:)
    end

    # @rbs (Message?, MessageReference, timeout: Numeric) -> SyncTimeout
    def contention_timeout(message, message_reference, timeout:)
      return SyncDiagnostics.new.database_contention(message, timeout:) if message

      SyncDiagnostics.new.database_contention_for(message_reference, timeout:)
    end

    # @rbs () -> Float
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
