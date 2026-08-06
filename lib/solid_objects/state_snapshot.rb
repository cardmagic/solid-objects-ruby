# rbs_inline: enabled

module SolidObjects
  class StateSnapshot
    # @rbs @actor_class: Class
    # @rbs @data: Hash[String, untyped]

    # @rbs (Reference) -> void
    def initialize(reference)
      actor_snapshot = ActorSnapshot.new(reference)
      @actor_class = actor_snapshot.actor_class
      @data = Serialization.readonly_copy(actor_snapshot.actor.state.to_h)
    end

    # @rbs () -> Hash[String, untyped]
    def to_h
      data
    end

    # @rbs (Symbol, *untyped, **untyped) -> untyped
    def method_missing(name, *arguments, **keywords)
      return data.fetch(name.to_s) if arguments.empty? && keywords.empty? && attribute?(name)

      super
    end

    # @rbs (Symbol, bool) -> bool
    def respond_to_missing?(name, include_private = false)
      attribute?(name) || super
    end

    private

    attr_reader :actor_class, :data

    # @rbs (Symbol | String) -> bool
    def attribute?(name)
      actor_class.definition.state_definition.to_h.key?(name.to_sym)
    end
  end
end
