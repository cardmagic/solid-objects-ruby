# rbs_inline: enabled

module SolidObjects
  class PollingBackoff
    # @rbs @minimum_interval: Float
    # @rbs @maximum_interval: Float
    # @rbs @current_interval: Float
    # @rbs @on_change: Proc?

    attr_reader :current_interval

    # @rbs (minimum_interval: Numeric, maximum_interval: Numeric, ?on_change: Proc?) -> void
    def initialize(minimum_interval:, maximum_interval:, on_change: nil)
      @minimum_interval = minimum_interval.to_f
      @maximum_interval = [ @minimum_interval, maximum_interval.to_f ].max
      @current_interval = @minimum_interval
      @on_change = on_change
    end

    # @rbs () -> void
    def record_idle
      change([ current_interval * 2, @maximum_interval ].min, :idle)
    end

    # @rbs (:work | :wake_up) -> void
    def reset(reason)
      change(@minimum_interval, reason)
    end

    private

    # @rbs (Float, :idle | :work | :wake_up) -> void
    def change(interval, reason)
      return if interval == current_interval

      previous_interval = current_interval
      @current_interval = interval
      @on_change&.call(
        previous_interval:,
        current_interval: interval,
        reason:
      )
    end
  end
end
