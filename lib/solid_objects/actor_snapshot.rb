# rbs_inline: enabled

module SolidObjects
  class ActorSnapshot
    # @rbs @reference: Reference
    # @rbs @actor_class: Class
    # @rbs @actor: Actor
    # @rbs @instance_id: Integer
    # @rbs @revision: Integer
    # @rbs @observable_values: Hash[String, untyped]?
    # @rbs @observable_value_cache: Hash[String, untyped]

    attr_reader :reference, :actor_class, :actor, :instance_id, :revision

    # @rbs (Reference) -> void
    def initialize(reference)
      @reference = reference
      @actor_class = SolidObjects.registry.fetch(reference.actor_type)
      @instance = Instance.find_by(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id
      )
      @instance_id = @instance&.id || 0
      @revision = @instance&.state_revision || 0
      @actor = build_actor
      @observable_values = nil
      @observable_value_cache = {}
    end

    # @rbs () -> Hash[String, untyped]
    def observable_values
      @observable_values ||= Serialization.readonly_copy(actor.observable_values)
    end

    # @rbs (Symbol | String) -> untyped
    def observable_value(name)
      observable_name = name.to_s
      return @observable_value_cache.fetch(observable_name) if @observable_value_cache.key?(observable_name)

      @observable_value_cache[observable_name] =
        Serialization.readonly_copy(actor.observable_value(observable_name))
    end

    private

    attr_reader :instance

    # @rbs () -> Actor
    def build_actor
      state_version = instance&.state_version || actor_class.state_version
      state_data = ApplicationWriteGuard.call(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        operation: "state_migration"
      ) do
        actor_class.definition.migrate_state(
          state_version,
          instance&.state || {}
        )
      end
      actor_class.new(
        actor_id: reference.actor_id,
        state: State.new(actor_class.definition.state_definition, state_data)
      )
    end
  end
end
