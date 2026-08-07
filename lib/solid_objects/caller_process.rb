# rbs_inline: enabled

module SolidObjects
  class CallerProcess
    # @rbs @mutex: Thread::Mutex
    # @rbs @process_id: Integer?
    # @rbs @registry: ProcessRegistry?
    # @rbs @shutdown_hook_installed: bool

    # @rbs () -> void
    def initialize
      @mutex = Thread::Mutex.new
      @process_id = nil
      @registry = nil
      @shutdown_hook_installed = false
    end

    # @rbs () -> ProcessRegistry
    def process_registry
      mutex.synchronize do
        reset_after_fork
        register unless reusable_registry?
        install_shutdown_hook
        registry.heartbeat
        registry
      end
    end

    # @rbs () -> String?
    def process_record_id
      mutex.synchronize do
        reset_after_fork
        registry&.process_record&.id
      end
    end

    # @rbs () -> bool
    def stop
      mutex.synchronize do
        return false unless @process_id == ::Process.pid
        return false unless registry&.process_record

        registry.stop.tap { @registry = nil }
      end
    end

    # @rbs (String) -> bool
    def delete_process_record(process_id)
      mutex.synchronize do
        reset_after_fork
        process_record = registry&.process_record
        return false unless process_record&.id == process_id

        registry.stop
        process_record.delete
        @registry = nil
        true
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

      SolidObjects.database_adapter.with_lock_retry do
        registry.process_record.reload.shutdown_state == "running"
      end
    rescue ActiveRecord::RecordNotFound
      false
    end

    # @rbs () -> ProcessRegistry
    def register
      process_registry = ProcessRegistry.new
      process_registry.register(
        kind: "caller",
        metadata: { execution: "synchronous" }
      )
      @registry = process_registry
    end

    # @rbs () -> void
    def install_shutdown_hook
      return if @shutdown_hook_installed

      @shutdown_hook_installed = true
      at_exit { stop_after_exit }
    end

    # @rbs () -> bool
    def stop_after_exit
      stop
    rescue
      false
    end
  end
end
