# rbs_inline: enabled

module SolidObjects
  class EffectRegistry
    # @rbs @handlers: Hash[String, Proc]
    # @rbs @mutex: Mutex

    # @rbs () -> void
    def initialize
      @handlers = {}
      @mutex = Mutex.new
    end

    # @rbs (String | Symbol, Proc) -> Proc
    def register(name, handler)
      effect_name = name.to_s
      raise ArgumentError, "effect name cannot be empty" if effect_name.empty?

      mutex.synchronize { handlers[effect_name] = handler }
      handler
    end

    # @rbs (String | Symbol) -> Proc
    def fetch(name)
      handlers.fetch(name.to_s) do
        raise InvalidActor, "no effect handler registered for #{name.inspect}"
      end
    end

    private

    attr_reader :handlers, :mutex
  end
end
