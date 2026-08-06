# rbs_inline: enabled

module SolidObjects
  class CallerProcess
    # @rbs @mutex: Thread::Mutex
    # @rbs @process_id: Integer?
    # @rbs @registry: ProcessRegistry?

    # @rbs () -> void
    def initialize
      @mutex = Thread::Mutex.new
      @process_id = nil
      @registry = nil
    end

    # @rbs () -> ProcessRegistry
    def process_registry
      mutex.synchronize do
        reset_after_fork
        register unless reusable_registry?
        registry.heartbeat
        registry
      end
    end

    private

    attr_reader :mutex, :registry

    # @rbs () -> void
    def reset_after_fork
      return if @process_id == ::Process.pid

      @process_id = ::Process.pid
      @registry = nil
    end

    # @rbs () -> bool
    def reusable_registry?
      return false unless registry&.process_record

      registry.process_record.reload.shutdown_state == "running"
    rescue ActiveRecord::RecordNotFound
      false
    end

    # @rbs () -> ProcessRegistry
    def register
      @registry = ProcessRegistry.new
      registry.register(
        kind: "caller",
        metadata: { execution: "synchronous" }
      )
      registry
    end
  end
end
