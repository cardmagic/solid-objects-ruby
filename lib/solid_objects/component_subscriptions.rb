# rbs_inline: enabled

module SolidObjects
  class ComponentSubscriptions
    MAXIMUM_COMPONENTS = 50
    MAXIMUM_SERIALIZED_BYTES = 1_048_576

    # @rbs @registrations: Array[ComponentRegistration]
    # @rbs @revisions: Hash[String, Array[Integer]]

    # @rbs (String?, reference: Reference) -> ComponentSubscriptions
    def self.parse(serialized, reference:)
      return new([]) unless serialized
      unless serialized.is_a?(String) &&
          serialized.bytesize <= MAXIMUM_SERIALIZED_BYTES
        raise InvalidComponentToken, "invalid actor component registrations"
      end

      tokens = JSON.parse(serialized)
      unless tokens.is_a?(Array) &&
          tokens.length <= MAXIMUM_COMPONENTS &&
          tokens.all? { |token| token.is_a?(String) }
        raise InvalidComponentToken, "invalid actor component registrations"
      end

      registrations = tokens.map do |token|
        ComponentRegistration.from_token(token).tap do |registration|
          validate_identity!(registration, reference)
        end
      end
      if registrations.map(&:dom_id).uniq.length != registrations.length
        raise InvalidComponentToken, "duplicate actor component registration"
      end

      new(registrations)
    end

    # @rbs (Array[ComponentRegistration]) -> void
    def initialize(registrations)
      @registrations = registrations
      @revisions = registrations.to_h do |registration|
        [ registration.dom_id, registration.revision_key ]
      end
    end

    # @rbs (Hash[String, untyped]) -> Array[String]
    def refreshes_for(invalidation)
      observable_name = invalidation.fetch("observable_name")
      instance_id = invalidation.fetch("instance_id")
      revision = invalidation.fetch("revision")
      registrations.filter_map do |registration|
        next unless registration.dependencies.include?(observable_name)
        next unless newer_revision?(
          registration.dom_id,
          instance_id,
          revision
        )

        refresh(registration, instance_id, revision)
      end
    end

    # @rbs (ActorSnapshot) -> Array[String]
    def reconnect_refreshes(snapshot)
      registrations.filter_map do |registration|
        next unless newer_revision?(
          registration.dom_id,
          snapshot.instance_id,
          snapshot.revision
        )

        refresh(registration, snapshot.instance_id, snapshot.revision)
      end
    end

    class << self
      private

      # @rbs (ComponentRegistration, Reference) -> void
      def validate_identity!(registration, reference)
        return if registration.reference.actor_type == reference.actor_type &&
          registration.reference.actor_id == reference.actor_id

        raise InvalidComponentToken,
          "actor component identity does not match its subscription"
      end
    end

    private

    attr_reader :registrations, :revisions

    # @rbs (ComponentRegistration, Integer, Integer) -> String
    def refresh(registration, instance_id, revision)
      revisions[registration.dom_id] = [ instance_id, revision ]
      TurboStreamRenderer.component_refresh(
        registration,
        instance_id,
        revision
      )
    end

    # @rbs (String, Integer, Integer) -> bool
    def newer_revision?(dom_id, instance_id, revision)
      current = revisions.fetch(dom_id)
      (current <=> [ instance_id, revision ]) == -1
    end
  end
end
