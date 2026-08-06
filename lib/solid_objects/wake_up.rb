# rbs_inline: enabled

module SolidObjects
  class WakeUp
    # @rbs @mutex: Mutex
    # @rbs @condition: Thread::ConditionVariable

    # @rbs () -> void
    def initialize
      @mutex = Mutex.new
      @condition = Thread::ConditionVariable.new
    end

    # @rbs () -> void
    def signal
      mutex.synchronize { condition.broadcast }
    end

    # @rbs (timeout: Numeric) -> void
    def wait(timeout:)
      mutex.synchronize { condition.wait(mutex, timeout) }
    end

    private

    attr_reader :mutex, :condition
  end
end
