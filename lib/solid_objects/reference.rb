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

    # @rbs (?available_at: Time?, ?idempotency_key: String?, ?authorization_context: untyped) -> OperationDispatcher
    def async(available_at: nil, idempotency_key: nil, authorization_context: nil)
      OperationDispatcher.new(
        actor_type:,
        handlers: actor_definition.messages
      ) do |message_name, arguments|
        if (actor = Context.current_actor)
          actor.stage_outbound_message(
            self,
            message_name,
            arguments,
            available_at:,
            idempotency_key:
          )
          next
        end

        SolidObjects.client.async(
          self,
          message_name,
          arguments,
          available_at:,
          idempotency_key:,
          authorization_context:
        )
      end
    end

    # @rbs (?timeout: Numeric, ?idempotency_key: String?, ?authorization_context: untyped) -> OperationDispatcher
    def sync(timeout: 5.seconds, idempotency_key: nil, authorization_context: nil)
      raise ActorCallCycle, "actors cannot synchronously wait for another actor" if Context.current_actor

      OperationDispatcher.new(
        actor_type:,
        handlers: actor_definition.messages.merge(actor_definition.queries)
      ) do |message_name, arguments|
        invoke_synchronously(
          message_name,
          arguments,
          timeout:,
          idempotency_key:,
          authorization_context:
        )
      end
    end

    # @rbs (?authorization_context: untyped) -> bool
    def destroy(authorization_context: nil)
      SolidObjects.client.destroy(self, authorization_context:)
    end

    # @rbs (?authorization_context: untyped) -> StateSnapshot
    def snapshot(authorization_context: nil)
      SolidObjects.client.snapshot(self, authorization_context:)
    end

    # @rbs (Symbol, *untyped, **untyped) -> untyped
    def method_missing(name, *arguments, **keywords)
      return super if arguments.any? || block_given?
      if actor_message?(name) || actor_query?(name)
        return invoke_synchronously(
          name,
          keywords,
          timeout: 5.seconds,
          idempotency_key: nil,
          authorization_context: nil
        )
      end

      super
    end

    # @rbs (Symbol, bool) -> bool
    def respond_to_missing?(name, include_private = false)
      actor_message?(name) || actor_query?(name) || super
    end

    # @rbs () -> String
    def to_s
      "#{actor_type}(#{actor_id.inspect})"
    end

    private

    # @rbs (Symbol | String, Hash[Symbol, untyped], timeout: Numeric, idempotency_key: String?, authorization_context: untyped) -> untyped
    def invoke_synchronously(message_name, arguments, timeout:, idempotency_key:, authorization_context:)
      raise ActorCallCycle, "actors cannot synchronously wait for another actor" if Context.current_actor

      SolidObjects.client.sync(
        self,
        message_name,
        arguments,
        timeout:,
        idempotency_key:,
        authorization_context:
      )
    end

    # @rbs (Symbol | String) -> bool
    def actor_message?(name)
      actor_definition.messages.key?(name.to_sym)
    end

    # @rbs (Symbol | String) -> bool
    def actor_query?(name)
      actor_definition.queries.key?(name.to_sym)
    end

    # @rbs () -> ActorDefinition
    def actor_definition
      SolidObjects.registry.fetch(actor_type).definition
    end
  end
end
