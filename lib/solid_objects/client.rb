# rbs_inline: enabled

require "solid_objects/mailbox"

module SolidObjects
  class Client
    # @rbs @mailbox: Mailbox

    # @rbs (?mailbox: Mailbox) -> void
    def initialize(mailbox: Mailbox.new)
      @mailbox = mailbox
    end

    # @rbs (Reference, Symbol | String, Hash[Symbol | String, untyped], ?available_at: Time?, ?idempotency_key: String?, ?authorization_context: untyped) -> MessageReference
    def tell(reference, message_name, arguments, available_at: nil, idempotency_key: nil, authorization_context: nil)
      actor_class = SolidObjects.registry.fetch(reference.actor_type)
      message_symbol = message_name.to_sym
      raise UnknownMessage, "unknown message #{message_name.inspect}" unless actor_class.definition.messages.key?(message_symbol)

      authorize!(
        SolidObjects.configuration.authorize_message,
        reference,
        message_name,
        arguments,
        authorization_context:
      )
      mailbox.enqueue(
        reference,
        message_name,
        arguments,
        kind: "tell",
        available_at:,
        idempotency_key:
      )
    end

    # @rbs (Reference, Symbol | String, Hash[Symbol | String, untyped], timeout: Numeric, ?idempotency_key: String?, ?authorization_context: untyped) -> untyped
    def ask(reference, message_name, arguments, timeout:, idempotency_key: nil, authorization_context: nil)
      actor_class = SolidObjects.registry.fetch(reference.actor_type)
      message_symbol = message_name.to_sym
      query = actor_class.definition.queries.key?(message_symbol)
      actor_message = actor_class.definition.messages.key?(message_symbol)
      raise UnknownMessage, "unknown message #{message_name.inspect}" unless query || actor_message

      authorize!(
        query ? SolidObjects.configuration.authorize_query : SolidObjects.configuration.authorize_message,
        reference,
        message_name,
        arguments,
        authorization_context:
      )
      message_reference = mailbox.enqueue(
        reference,
        message_name,
        arguments,
        kind: "ask",
        idempotency_key:
      )
      wait_for_result(message_reference, timeout:)
    end

    private

    attr_reader :mailbox

    # @rbs (Proc, Reference, Symbol | String, Hash[Symbol | String, untyped], authorization_context: untyped) -> void
    def authorize!(hook, reference, message_name, arguments, authorization_context:)
      authorized = hook.call(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        message_name: message_name.to_s,
        arguments:,
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor invocation is not authorized"
    end

    # @rbs (MessageReference, timeout: Numeric) -> untyped
    def wait_for_result(message_reference, timeout:)
      deadline = monotonic_now + timeout.to_f

      loop do
        message = Message.uncached { Message.find(message_reference.id) }
        return message.result if message.completed?

        if message.dead?
          raise MessageFailed.new(
            "actor message failed permanently",
            message_id: message.id,
            details: message.error || {}
          )
        end

        remaining = deadline - monotonic_now
        raise AskTimeout, "actor request timed out after #{timeout} seconds" unless remaining.positive?

        SolidObjects.wake_up.wait(
          timeout: [ remaining, SolidObjects.configuration.ask_polling_interval ].min
        )
      end
    end

    # @rbs () -> Float
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
