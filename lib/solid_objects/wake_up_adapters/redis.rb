# rbs_inline: enabled

require "timeout"

module SolidObjects
  module WakeUpAdapters
    # Wakes runtime roles across processes using Redis publish/subscribe.
    #
    # MySQL has no notification primitive, so this is the cross-process option
    # for applications that cannot use PostgreSQL notifications. It is optional
    # in every sense: the `redis` gem is not a dependency of this gem, and the
    # polling interval remains the upper bound, so a missed or failed
    # notification costs latency rather than correctness.
    class Redis
      CHANNEL = "solid_objects_wake_up"
      FAILED_WAIT_INTERVAL = 0.05
      SUBSCRIBE_TIMEOUT = 5.0

      # @rbs @channel: String
      # @rbs @url: String?
      # @rbs @client: untyped
      # @rbs @mutex: Thread::Mutex
      # @rbs @condition: Thread::ConditionVariable
      # @rbs @subscriber: Thread?
      # @rbs @subscription: untyped
      # @rbs @signalled: Integer

      attr_reader :channel

      # @rbs (?channel: String, ?url: String?, ?client: untyped) -> void
      def initialize(channel: CHANNEL, url: nil, client: nil)
        @channel = channel
        @url = url
        @client = client
        @mutex = Thread::Mutex.new
        @condition = Thread::ConditionVariable.new
        @subscriber = nil
        @subscription = nil
        @signalled = 0
        validate_client!
      end

      # @rbs () -> bool
      def signal
        publisher.publish(channel, "1")
        true
      rescue => error
        instrument_failure(:signal, error)
        false
      end

      # @rbs (timeout: Numeric) -> bool
      def wait(timeout:)
        return paced_failure(timeout) unless listen

        mutex.synchronize do
          signalled = @signalled
          condition.wait(mutex, timeout.to_f)
          @signalled != signalled
        end
      end

      # Redis delivers to a subscribed connection only, and a subscribed
      # connection cannot serve other callers, so one background subscription
      # per process fans out to every waiting role in memory. Subscribing
      # eagerly also closes the window where a signal sent during startup would
      # be missed.
      # @rbs () -> bool
      def listen
        mutex.synchronize do
          return true if @subscriber&.alive?

          ready = Queue.new
          @subscriber = Thread.new { subscribe_loop(ready) }
          Timeout.timeout(SUBSCRIBE_TIMEOUT) { ready.pop } == :subscribed
        end
      rescue => error
        instrument_failure(:listen, error)
        false
      end

      # @rbs () -> bool
      def stop
        subscriber = mutex.synchronize do
          thread = @subscriber
          @subscriber = nil
          thread
        end
        return false unless subscriber

        disconnect(@subscription)
        subscriber.join(SUBSCRIBE_TIMEOUT)
        subscriber.kill if subscriber.alive?
        true
      end

      private

      attr_reader :mutex, :condition, :url

      # @rbs (Queue) -> void
      def subscribe_loop(ready)
        connection = build_client
        @subscription = connection
        connection.subscribe(channel) do |on|
          on.subscribe { ready << :subscribed }
          on.message { broadcast }
        end
      rescue => error
        instrument_failure(:subscribe, error)
        ready << :failed
      end

      # @rbs () -> void
      def broadcast
        mutex.synchronize do
          @signalled += 1
          condition.broadcast
        end
      end

      # @rbs (Numeric) -> bool
      def paced_failure(timeout)
        pace_after_failure(timeout)
        false
      end

      # @rbs () -> untyped
      def publisher
        @publisher ||= build_client
      end

      # @rbs () -> untyped
      def build_client
        return @client.call if @client.respond_to?(:call)

        require "redis"
        url ? ::Redis.new(url:) : ::Redis.new
      rescue LoadError
        raise ArgumentError,
          "the redis gem is required for SolidObjects::WakeUpAdapters::Redis"
      end

      # @rbs () -> void
      def validate_client!
        return if @client.nil? || @client.respond_to?(:call)

        raise ArgumentError, "client must respond to call and return a Redis client"
      end

      # @rbs (untyped) -> void
      def disconnect(connection)
        connection&.close
      rescue
        nil
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
          adapter: "redis",
          operation: operation.to_s,
          error_class: error.class.name,
          error_message: error.message
        )
      end
    end
  end
end
