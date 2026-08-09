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
        handler.block.call(snapshot.actor, authorization_context),
        max_bytes: MAXIMUM_PAYLOAD_BYTES
      )
      return payload if payload.is_a?(Hash) || payload.is_a?(Array)

      raise InvalidPayloadBroadcast,
        "payload broadcast #{name.inspect} must return a JSON object or array"
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
