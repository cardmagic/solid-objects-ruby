# rbs_inline: enabled

require "solid_objects/mailbox"
require "solid_objects/synchronous_invocation"

module SolidObjects
  class Client
    # @rbs @mailbox: Mailbox

    # @rbs (?mailbox: Mailbox) -> void
    def initialize(mailbox: Mailbox.new)
      @mailbox = mailbox
    end

    # @rbs (Reference, Symbol | String, Hash[Symbol | String, untyped], ?available_at: Time?, ?idempotency_key: String?, ?authorization_context: untyped) -> MessageReference
    def async(reference, message_name, arguments, available_at: nil, idempotency_key: nil, authorization_context: nil)
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
        kind: "async",
        available_at:,
        idempotency_key:
      )
    end

    # @rbs (Reference, Symbol | String, Hash[Symbol | String, untyped], timeout: Numeric, ?idempotency_key: String?, ?authorization_context: untyped) -> untyped
    def sync(reference, message_name, arguments, timeout:, idempotency_key: nil, authorization_context: nil)
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
        kind: "sync",
        idempotency_key:
      )
      SynchronousInvocation.new.call(message_reference, timeout:)
    end

    # @rbs (Reference, ?authorization_context: untyped) -> bool
    def destroy(reference, authorization_context: nil)
      raise ActorCallCycle, "actors cannot synchronously destroy another actor" if Context.current_actor

      SolidObjects.registry.fetch(reference.actor_type)
      authorize_destroy!(reference, authorization_context:)
      instance_id = SolidObjects.database_adapter.transaction do
        instance = Instance.lock.find_by(
          actor_type: reference.actor_type,
          actor_id: reference.actor_id
        )
        next unless instance

        instance_id = instance.id
        instance.delete
        instance_id
      end
      return false unless instance_id

      SolidObjects.instrument(
        :"actor.destroyed",
        instance_id:,
        actor_type: reference.actor_type,
        actor_id: reference.actor_id
      )
      SolidObjects.wake_up.signal
      true
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

    # @rbs (Reference, authorization_context: untyped) -> void
    def authorize_destroy!(reference, authorization_context:)
      authorized = SolidObjects.configuration.authorize_destroy.call(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor destruction is not authorized"
    end
  end
end
