# rbs_inline: enabled

module SolidObjects
  CommitActionContext = Data.define(
    :message_id,
    :request_id,
    :actor_type,
    :actor_id,
    :activation_generation
  )

  class CommitActionRegistry
    # @rbs @handlers: Hash[String, Proc]
    # @rbs @mutex: Mutex

    # @rbs () -> void
    def initialize
      @handlers = {}
      @mutex = Mutex.new
    end

    # @rbs (String | Symbol, Proc) -> Proc
    def register(name, handler)
      action_name = name.to_s
      raise ArgumentError, "commit action name cannot be empty" if action_name.empty?

      mutex.synchronize { handlers[action_name] = handler }
      handler
    end

    # @rbs (String | Symbol) -> Proc
    def fetch(name)
      handlers.fetch(name.to_s) do
        raise UnknownCommitAction, "no commit action registered for #{name.inspect}"
      end
    end

    private

    attr_reader :handlers, :mutex
  end
end
