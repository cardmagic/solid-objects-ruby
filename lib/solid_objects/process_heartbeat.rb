# rbs_inline: enabled

module SolidObjects
  class ProcessHeartbeat
    # @rbs @process_registry: ProcessRegistry
    # @rbs @mutex: Thread::Mutex
    # @rbs @condition: Thread::ConditionVariable
    # @rbs @stopped: bool
    # @rbs @thread: Thread?

    # @rbs (process_registry: ProcessRegistry) -> void
    def initialize(process_registry:)
      @process_registry = process_registry
      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @stopped = false
      @thread = nil
    end

    # @rbs () -> void
    def start
      @thread = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          break if wait_for_interval

          Record.connection_pool.with_connection { process_registry.heartbeat }
        rescue => error
          report_failure(error)
        end
      end
    end

    # @rbs () -> void
    def stop
      mutex.synchronize do
        @stopped = true
        condition.broadcast
      end
      @thread&.join
    end

    private

    attr_reader :process_registry, :mutex, :condition

    # @rbs (Exception) -> void
    def report_failure(error)
      payload = { process_id: process_registry.process_record&.id, error_class: error.class.name }
      SolidObjects.configuration.logger.warn({ event: "solid_objects.process.heartbeat_failed", **payload })
      SolidObjects.instrument(:"process.heartbeat_failed", **payload)
    rescue
      nil
    end

    # @rbs () -> bool
    def wait_for_interval
      mutex.synchronize do
        condition.wait(mutex, SolidObjects.configuration.process_heartbeat_interval) unless @stopped
        @stopped
      end
    end
  end
end
