# rbs_inline: enabled

module SolidObjects
  class LeaseRenewer
    # @rbs @activation: Activation
    # @rbs @process_registry: ProcessRegistry
    # @rbs @mutex: Thread::Mutex
    # @rbs @condition: Thread::ConditionVariable
    # @rbs @stopped: bool
    # @rbs @thread: Thread?

    # @rbs (activation: Activation, process_registry: ProcessRegistry) -> void
    def initialize(activation:, process_registry:)
      @activation = activation
      @process_registry = process_registry
      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @stopped = false
      @thread = nil
    end

    # @rbs () { () -> untyped } -> untyped
    def around
      start
      yield
    ensure
      stop
    end

    private

    attr_reader :activation, :process_registry, :mutex, :condition

    # @rbs () -> void
    def start
      @thread = Thread.new do
        loop do
          break if wait_for_interval

          activation.renew_lease
          process_registry.heartbeat
        rescue LostActivation
          break
        end
      end
    end

    # @rbs () -> bool
    def wait_for_interval
      mutex.synchronize do
        unless @stopped
          condition.wait(
            mutex,
            SolidObjects.configuration.lease_renewal_interval
          )
        end
        @stopped
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
  end
end
