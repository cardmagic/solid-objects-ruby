# rbs_inline: enabled

module SolidObjects
  module WakeUpAdapters
    # Wakes runtime roles across processes using PostgreSQL notifications.
    #
    # The in-process wake-up cannot reach another process, so a commit in a web
    # process leaves a worker waiting out its polling interval. This adapter
    # keeps that polling interval as the upper bound and delivers a notification
    # when one is available, so a missed or failed notification costs latency
    # rather than correctness.
    class Postgresql
      CHANNEL = "solid_objects_wake_up"
      FAILED_WAIT_INTERVAL = 0.05

      # @rbs @channel: String
      # @rbs @mutex: Thread::Mutex
      # @rbs @connection: untyped

      attr_reader :channel

      # @rbs (?channel: String) -> void
      def initialize(channel: CHANNEL)
        @channel = channel
        @mutex = Thread::Mutex.new
        @connection = nil
      end

      # @rbs () -> bool
      def signal
        notify_channel
        true
      rescue => error
        instrument_failure(:signal, error)
        false
      end

      # @rbs (timeout: Numeric) -> bool
      def wait(timeout:)
        connection = listening_connection
        !connection.raw_connection.wait_for_notify(timeout.to_f).nil?
      rescue => error
        instrument_failure(:wait, error)
        pace_after_failure(timeout)
        false
      end

      # Starts listening before a caller blocks, so a notification sent between
      # startup and the first wait is not missed.
      # @rbs () -> bool
      def listen
        listening_connection
        true
      rescue => error
        instrument_failure(:listen, error)
        false
      end

      # @rbs () -> bool
      def stop
        mutex.synchronize do
          connection = @connection
          @connection = nil
          return false unless connection

          connection.disconnect!
          true
        end
      rescue
        false
      end

      private

      attr_reader :mutex

      # @rbs () -> void
      def notify_channel
        Record.connection_pool.with_connection do |connection|
          connection.execute("NOTIFY #{connection.quote_table_name(channel)}")
        end
      end

      # A listening connection is dedicated: `LISTEN` is per connection, and a
      # blocking wait must not hold a connection the rest of the runtime needs.
      # @rbs () -> untyped
      def listening_connection
        mutex.synchronize do
          return @connection if @connection&.active?

          @connection = Record.connection_pool.send(:new_connection)
          @connection.execute("LISTEN #{@connection.quote_table_name(channel)}")
          @connection
        end
      end

      # @rbs (Numeric) -> void
      def pace_after_failure(timeout)
        interval = [ timeout.to_f, FAILED_WAIT_INTERVAL ].min
        return unless interval.positive?

        sleep interval
      end

      # @rbs (Symbol, Exception) -> void
      def instrument_failure(operation, error)
        SolidObjects.instrument(
          :"wake_up.failed",
          adapter: "postgresql",
          operation: operation.to_s,
          error_class: error.class.name,
          error_message: error.message
        )
      end
    end
  end
end
