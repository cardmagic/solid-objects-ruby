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
      changed = registrations.select do |registration|
        registration.dependencies.include?(observable_name) &&
          newer_revision?(registration.dom_id, instance_id, revision)
      end
      refresh_streams(changed, instance_id, revision)
    end

    # @rbs (ActorSnapshot) -> Array[String]
    def reconnect_refreshes(snapshot)
      stale = registrations.select do |registration|
        newer_revision?(
          registration.dom_id,
          snapshot.instance_id,
          snapshot.revision
        )
      end
      refresh_streams(stale, snapshot.instance_id, snapshot.revision)
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

    # Live invalidations and reconnect replays share this, so a reconnecting
    # client pays the same number of requests a connected one does.
    # @rbs (Array[ComponentRegistration], Integer, Integer) -> Array[String]
    def refresh_streams(changed, instance_id, revision)
      batched, individual = changed.partition(&:batch)
      streams = individual.map do |registration|
        refresh(registration, instance_id, revision)
      end
      batched.group_by(&:batch).each_value do |group|
        group.each { |registration| record_revision(registration, instance_id, revision) }
        streams << TurboStreamRenderer.batch_refresh(group, instance_id, revision)
      end
      streams
    end

    # @rbs (ComponentRegistration, Integer, Integer) -> void
    def record_revision(registration, instance_id, revision)
      revisions[registration.dom_id] = [ instance_id, revision ]
    end

    # @rbs (ComponentRegistration, Integer, Integer) -> String
    def refresh(registration, instance_id, revision)
      record_revision(registration, instance_id, revision)
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
