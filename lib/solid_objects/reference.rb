# rbs_inline: enabled

module SolidObjects
  class Reference
    # @rbs @actor_type: String
    # @rbs @actor_id: String

    attr_reader :actor_type, :actor_id

    # @rbs (actor_type: String, actor_id: String) -> void
    def initialize(actor_type:, actor_id:)
      raise InvalidActor, "actor ID cannot be empty" if actor_id.empty?

      @actor_type = actor_type
      @actor_id = actor_id
      freeze
    end

    # @rbs (Symbol | String, ?available_at: Time?, ?idempotency_key: String?, ?authorization_context: untyped, **untyped) -> (MessageReference | Actor::OutboundMessageIntent)
    def tell(message_name, available_at: nil, idempotency_key: nil, authorization_context: nil, **arguments)
      if (actor = Context.current_actor)
        return actor.stage_outbound_message(
          self,
          message_name,
          arguments,
          available_at:,
          idempotency_key:
        )
      end

      SolidObjects.client.tell(
        self,
        message_name,
        arguments,
        available_at:,
        idempotency_key:,
        authorization_context:
      )
    end

    # @rbs (Symbol | String, ?timeout: Numeric, ?idempotency_key: String?, ?authorization_context: untyped, **untyped) -> untyped
    def ask(message_name, timeout: 5.seconds, idempotency_key: nil, authorization_context: nil, **arguments)
      raise ActorCallCycle, "actors cannot synchronously wait for another actor" if Context.current_actor

      SolidObjects.client.ask(
        self,
        message_name,
        arguments,
        timeout:,
        idempotency_key:,
        authorization_context:
      )
    end

    # @rbs () -> String
    def to_s
      "#{actor_type}(#{actor_id.inspect})"
    end
  end
end
