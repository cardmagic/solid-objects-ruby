# rbs_inline: enabled

module SolidObjects
  class ComponentView
    # @rbs @snapshot: ActorSnapshot
    # @rbs @dependencies: Array[String]
    # @rbs @authorization_context: untyped

    attr_reader :authorization_context

    # @rbs (snapshot: ActorSnapshot, dependencies: Array[String], authorization_context: untyped) -> void
    def initialize(snapshot:, dependencies:, authorization_context:)
      @snapshot = snapshot
      @dependencies = dependencies
      @authorization_context = authorization_context
    end

    # @rbs () -> Reference
    def reference
      snapshot.reference
    end

    # @rbs () -> String
    def actor_id
      reference.actor_id
    end

    # @rbs () -> void
    def state
      raise UnknownComponentDependency,
        "reactive components must read declared observables instead of actor.state"
    end

    # @rbs (Symbol, *untyped, **untyped) -> untyped
    def method_missing(name, *arguments, **keywords)
      return super unless arguments.empty? && keywords.empty?
      return observable_value(name) if observable?(name)

      super
    end

    # @rbs (Symbol, bool) -> bool
    def respond_to_missing?(name, include_private = false)
      observable?(name) || super
    end

    private

    attr_reader :snapshot, :dependencies

    # @rbs (Symbol | String) -> bool
    def observable?(name)
      snapshot.actor_class.definition.observables.key?(name.to_sym)
    end

    # @rbs (Symbol | String) -> untyped
    def observable_value(name)
      dependency = name.to_s
      unless dependencies.include?(dependency)
        raise UnknownComponentDependency,
          "observable #{dependency.inspect} is not declared by this component"
      end

      snapshot.observable_value(dependency)
    end
  end
end
