# rbs_inline: enabled

module SolidObjects
  class ActorSnapshot
    # @rbs @reference: Reference
    # @rbs @actor_class: Class
    # @rbs @actor: Actor

    attr_reader :reference, :actor_class, :actor

    # @rbs (Reference) -> void
    def initialize(reference)
      @reference = reference
      @actor_class = SolidObjects.registry.fetch(reference.actor_type)
      @actor = build_actor
    end

    # @rbs () -> Hash[String, untyped]
    def observable_values
      actor.observable_values
    end

    private

    # @rbs () -> Actor
    def build_actor
      instance = Instance.find_by(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id
      )
      state_version = instance&.state_version || actor_class.state_version
      state_data = actor_class.definition.migrate_state(
        state_version,
        instance&.state || {}
      )
      actor_class.new(
        actor_id: reference.actor_id,
        state: State.new(actor_class.definition.state_definition, state_data)
      )
    end
  end
end
