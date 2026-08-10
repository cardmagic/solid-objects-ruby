# rbs_inline: enabled

module SolidObjects
  class PayloadBroadcast
    MAXIMUM_PAYLOAD_BYTES = 1_048_576
    REVISION_OBSERVABLE = "solid_objects.revision"

    # @rbs @snapshot: ActorSnapshot
    # @rbs @name: String
    # @rbs @authorization_context: untyped

    attr_reader :name

    # @rbs (snapshot: ActorSnapshot, name: String, authorization_context: untyped) -> void
    def initialize(snapshot:, name:, authorization_context:)
      @snapshot = snapshot
      @name = name
      @authorization_context = authorization_context
    end

    # @rbs () -> Hash[String, untyped]
    def call
      handler = snapshot.actor_class.definition.payload_broadcasts[name.to_sym]
      raise UnknownPayloadBroadcast, "unknown payload broadcast #{name.inspect}" unless handler

      authorize!
      {
        "actor_type" => snapshot.reference.actor_type,
        "actor_id" => snapshot.reference.actor_id,
        "name" => name,
        "instance_id" => snapshot.instance_id,
        "revision" => snapshot.revision,
        "payload" => rendered_payload(handler)
      }
    end

    private

    attr_reader :snapshot, :authorization_context

    # @rbs (ActorDefinition::Handler) -> untyped
    def rendered_payload(handler)
      payload = Serialization.dump(
        evaluated_payload(handler),
        max_bytes: MAXIMUM_PAYLOAD_BYTES
      )
      return payload if payload.is_a?(Hash) || payload.is_a?(Array)

      raise InvalidPayloadBroadcast,
        "payload broadcast #{name.inspect} must return a JSON object or array"
    end

    # The block runs against the actor instance, like every other block in the
    # actor DSL, and still receives the actor and the resolved authorization
    # context as arguments, so blocks written to the documented signature are
    # unaffected.
    # @rbs (ActorDefinition::Handler) -> untyped
    def evaluated_payload(handler)
      actor = snapshot.actor
      actor.instance_exec(actor, authorization_context, &handler.block)
    rescue NameError => error
      raise unless class_level_receiver?(error)

      raise InvalidPayloadBroadcast,
        "payload broadcast #{name.inspect} called #{error.name.inspect} on the " \
          "actor class. Payload blocks now run against the actor instance, like " \
          "every other actor block. Call it on the class explicitly."
    end

    # Distinguishes a block that relied on the old class-level receiver from an
    # ordinary typo, so the one behaviour change reports itself instead of
    # surfacing as an unexplained NameError.
    # @rbs (NameError[untyped]) -> bool
    def class_level_receiver?(error)
      error.receiver.equal?(snapshot.actor) &&
        snapshot.actor_class.respond_to?(error.name)
    rescue ArgumentError, NameError
      false
    end

    # @rbs () -> void
    def authorize!
      authorized = SolidObjects.configuration.authorize_query.call(
        actor_type: snapshot.reference.actor_type,
        actor_id: snapshot.reference.actor_id,
        message_name: name,
        arguments: {},
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor payload broadcast is not authorized"
    end
  end
end
