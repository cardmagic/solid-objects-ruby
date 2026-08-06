# rbs_inline: enabled

module SolidObjects
  MessageContext = Data.define(:id, :attempt, :enqueued_at, :idempotency_key, :request_id)

  module Context
    STORAGE_KEY = :solid_objects_context
    Frame = Data.define(:actor, :message, :authorization_context)

    class << self
      # @rbs () -> Frame?
      def current
        ActiveSupport::IsolatedExecutionState[STORAGE_KEY]
      end

      # @rbs () -> Actor?
      def current_actor
        current&.actor
      end

      # @rbs () -> MessageContext?
      def current_message
        current&.message
      end

      # @rbs () -> untyped
      def authorization_context
        current&.authorization_context
      end

      # @rbs (actor: Actor?, message: MessageContext?, authorization_context: untyped) { () -> untyped } -> untyped
      def with(actor:, message:, authorization_context: nil)
        previous = current
        ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = Frame.new(actor:, message:, authorization_context:)
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = previous
      end
    end
  end
end
