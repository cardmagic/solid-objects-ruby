# rbs_inline: enabled

module SolidObjects
  class OperationDispatcher
    # @rbs @actor_type: String
    # @rbs @handlers: Hash[Symbol, ActorDefinition::Handler]
    # @rbs @dispatch: Proc

    # @rbs (actor_type: String, handlers: Hash[Symbol, ActorDefinition::Handler]) { (Symbol, Hash[Symbol, untyped]) -> untyped } -> void
    def initialize(actor_type:, handlers:, &dispatch)
      @actor_type = actor_type
      @handlers = handlers.dup.freeze
      @dispatch = dispatch
    end

    # @rbs (Symbol, *untyped, **untyped) -> untyped
    def method_missing(name, *arguments, **keywords, &block)
      raise UnknownMessage, "unknown message #{name.inspect} for #{actor_type}" unless handlers.key?(name)
      if arguments.any? || block
        raise ArgumentError, "actor operations accept keyword arguments only"
      end

      dispatch.call(name, keywords)
    end

    # @rbs (Symbol, bool) -> bool
    def respond_to_missing?(name, include_private = false)
      handlers.key?(name) || super
    end

    private

    attr_reader :actor_type, :handlers, :dispatch
  end
end
