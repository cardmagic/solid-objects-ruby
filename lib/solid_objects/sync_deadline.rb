# rbs_inline: enabled

module SolidObjects
  class SyncDeadline
    KEY = :solid_objects_sync_deadline

    class << self
      # @rbs (timeout: Numeric) { () -> untyped } -> untyped
      def with(timeout:)
        previous_deadline = ActiveSupport::IsolatedExecutionState[KEY]
        ActiveSupport::IsolatedExecutionState[KEY] = monotonic_now + timeout.to_f
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[KEY] = previous_deadline
      end

      # @rbs () -> bool
      def active?
        !deadline.nil?
      end

      # @rbs () -> bool
      def expired?
        active? && !remaining.positive?
      end

      # @rbs () -> Float
      def remaining
        return Float::INFINITY unless deadline

        deadline - monotonic_now
      end

      # @rbs () -> Integer
      def remaining_milliseconds
        [ (remaining * 1_000).floor, 1 ].max
      end

      # @rbs () -> Integer
      def remaining_seconds
        [ remaining.ceil, 1 ].max
      end

      private

      # @rbs () -> Float?
      def deadline
        ActiveSupport::IsolatedExecutionState[KEY]
      end

      # @rbs () -> Float
      def monotonic_now
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
