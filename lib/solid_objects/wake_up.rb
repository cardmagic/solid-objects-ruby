# rbs_inline: enabled

module SolidObjects
  class WakeUp
    class Watch
      # @rbs @wake_up: WakeUp
      # @rbs @generation: Integer

      # @rbs (WakeUp, Integer) -> void
      def initialize(wake_up, generation)
        @wake_up = wake_up
        @generation = generation
      end

      # @rbs (timeout: Numeric) -> bool
      def wait(timeout:)
        @wake_up.wait(timeout:, generation: @generation)
      end
    end

    # @rbs @mutex: Mutex
    # @rbs @condition: Thread::ConditionVariable
    # @rbs @generation: Integer

    # @rbs () -> void
    def initialize
      @mutex = Mutex.new
      @condition = Thread::ConditionVariable.new
      @generation = 0
    end

    # @rbs () -> void
    def signal
      mutex.synchronize do
        @generation += 1
        condition.broadcast
      end
    end

    # @rbs () -> Watch
    def watch
      mutex.synchronize { Watch.new(self, @generation) }
    end

    # @rbs (timeout: Numeric, ?generation: Integer?) -> bool
    def wait(timeout:, generation: nil)
      mutex.synchronize do
        return true if generation && @generation != generation

        generation ||= @generation
        condition.wait(mutex, timeout)
        @generation != generation
      end
    end

    private

    attr_reader :mutex, :condition
  end
end
