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
      reject_sync_inside_transaction!(reference, message_name)
      SyncDeadline.with(timeout:) do
        message_reference = enqueue_sync(
          reference,
          message_name,
          arguments,
          idempotency_key:,
          timeout:
        )
        SynchronousInvocation.new.call(message_reference, timeout:)
      end
    end

    # @rbs (MessageReference, timeout: Numeric, ?authorization_context: untyped) -> untyped
    def wait(message_reference, timeout:, authorization_context: nil)
      SyncDeadline.with(timeout:) do
        message = SolidObjects.database_adapter.with_lock_retry do
          Message.find(message_reference.id)
        end
        validate_message_reference!(message_reference, message)
        reference = Reference.new(
          actor_type: message.actor_type,
          actor_id: message.actor_id
        )
        actor_class = SolidObjects.registry.fetch(reference.actor_type)
        query = actor_class.definition.queries.key?(message.message_name.to_sym)
        actor_message = actor_class.definition.messages.key?(message.message_name.to_sym)
        unless query || actor_message
          raise UnknownMessage, "unknown message #{message.message_name.inspect}"
        end
        authorize!(
          query ? SolidObjects.configuration.authorize_query : SolidObjects.configuration.authorize_message,
          reference,
          message.message_name,
          message.arguments,
          authorization_context:
        )
        reject_sync_inside_transaction!(reference, message.message_name)
        SynchronousInvocation.new.call(message_reference, timeout:)
      end
    rescue DatabaseDeadlineExceeded
      raise SyncDiagnostics.new.database_contention_for(message_reference, timeout:)
    end

    # @rbs (Reference, ?authorization_context: untyped) -> StateSnapshot
    def snapshot(reference, authorization_context: nil)
      SolidObjects.registry.fetch(reference.actor_type)
      authorize!(
        SolidObjects.configuration.authorize_query,
        reference,
        "__snapshot__",
        {},
        authorization_context:
      )
      StateSnapshot.new(reference)
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

    # @rbs (Reference, Symbol | String, Hash[Symbol | String, untyped], idempotency_key: String?, timeout: Numeric) -> MessageReference
    def enqueue_sync(reference, message_name, arguments, idempotency_key:, timeout:)
      mailbox.enqueue(
        reference,
        message_name,
        arguments,
        kind: "sync",
        idempotency_key:
      )
    rescue DatabaseDeadlineExceeded
      SolidObjects.instrument(
        :"sync.enqueue_timeout",
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        message_name: message_name.to_s
      )
      raise SyncEnqueueTimeout.new(
        timeout:,
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        message_name: message_name.to_s
      )
    end

    # @rbs (MessageReference, Message) -> void
    def validate_message_reference!(message_reference, message)
      valid = message_reference.request_id == message.request_id &&
        message_reference.actor_type == message.actor_type &&
        message_reference.actor_id == message.actor_id &&
        message_reference.sequence == message.sequence
      return if valid

      raise ActorDestroyed, "message reference no longer identifies this invocation"
    end

    # @rbs (Reference, Symbol | String) -> void
    def reject_sync_inside_transaction!(reference, message_name)
      return unless SolidObjects::Record.connection.transaction_open?

      SolidObjects.instrument(
        :"sync.transaction_rejected",
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        message_name: message_name.to_s
      )
      raise SyncInsideTransaction.new(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        message_name: message_name.to_s
      )
    end

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
