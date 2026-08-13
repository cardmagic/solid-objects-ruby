# rbs_inline: enabled

module SolidObjects
  module DatabaseAdapters
    class Sqlite < DatabaseAdapter
      LOCK_RETRY_INTERVAL = 0.001
      MAXIMUM_BUSY_RETRY_INTERVAL = 0.25
      LOCK_RETRY_MUTEX = Thread::Mutex.new
      LOCK_RETRY_CONDITION = Thread::ConditionVariable.new

      # @rbs () -> Gem::Version?
      def minimum_server_version
        Gem::Version.new("3.35")
      end

      # @rbs () -> String
      def current_time_expression
        "STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW')"
      end

      # @rbs () { () -> untyped } -> untyped
      def transaction(&block)
        return with_lock_retry { super } if SyncDeadline.active?

        with_busy_retry { super }
      end

      # A write outside a synchronous deadline has no Ruby-level budget, so it
      # depends entirely on SQLite's busy handler. Concurrent writers can
      # exhaust that, which surfaces as a lock error the caller cannot retry.
      # @rbs () { () -> untyped } -> untyped
      def with_busy_retry
        attempts = 0
        begin
          yield
        rescue => error
          raise unless busy_error?(error)

          attempts += 1
          raise if attempts > SolidObjects.configuration.lock_retry_attempts

          wait_before_busy_retry(attempts)
          retry
        end
      end

      # @rbs () { () -> untyped } -> untyped
      def with_lock_retry
        return yield unless SyncDeadline.active?

        raise DatabaseDeadlineExceeded, "synchronous invocation deadline expired" if SyncDeadline.expired?

        with_connection do |connection|
          with_transaction_deadline(connection) { yield }
        end
      rescue DatabaseDeadlineExceeded
        raise if SyncDeadline.expired?

        wait_before_retry
        retry
      rescue => error
        raise unless deadline_error?(error)

        if SyncDeadline.expired?
          raise DatabaseDeadlineExceeded,
            "database lock wait exceeded the synchronous invocation deadline",
            cause: error
        end

        wait_before_retry
        retry
      end

      # @rbs () { () -> untyped } -> untyped
      def with_lock_probe
        return yield unless SyncDeadline.active?

        with_connection do |connection|
          with_transaction_deadline(connection) { yield }
        end
      rescue => error
        raise unless deadline_error?(error)

        raise DatabaseDeadlineExceeded,
          "database remained locked at the synchronous invocation deadline",
          cause: error
      end

      private

      # @rbs (untyped) { () -> untyped } -> untyped
      def with_transaction_deadline(connection)
        return yield unless SyncDeadline.active?

        busy_wait = restorable_busy_wait(connection)
        return yield unless busy_wait

        begin
          connection.execute("PRAGMA busy_timeout = 0")
          yield
        ensure
          restore_busy_wait(connection, busy_wait)
        end
      end

      # @rbs (untyped) -> Hash[Symbol, untyped]?
      def restorable_busy_wait(connection)
        handler_timeout = configured_busy_handler_timeout(connection)
        return { handler_timeout: } if handler_timeout

        pragma_timeout = connection.select_value("PRAGMA busy_timeout").to_i
        return nil unless pragma_timeout.positive?

        { pragma_timeout: }
      end

      # @rbs (untyped, Hash[Symbol, untyped]) -> void
      def restore_busy_wait(connection, busy_wait)
        handler_timeout = busy_wait[:handler_timeout]
        if handler_timeout
          connection.raw_connection.busy_handler_timeout = handler_timeout
          return
        end

        connection.execute("PRAGMA busy_timeout = #{busy_wait.fetch(:pragma_timeout)}")
      end

      # @rbs (untyped) -> Integer?
      def configured_busy_handler_timeout(connection)
        return nil unless connection.respond_to?(:raw_connection)
        return nil unless connection.raw_connection.respond_to?(:busy_handler_timeout=)

        pool = connection.respond_to?(:pool) ? connection.pool : nil
        return nil unless pool.respond_to?(:db_config)

        timeout = pool.db_config.configuration_hash[:timeout]
        timeout&.to_i
      end

      # @rbs (Exception) -> bool
      def deadline_error?(error)
        return false unless SyncDeadline.active?

        busy_error?(error) || reconnect_blocked_error?(error)
      end

      # @rbs (Exception) -> bool
      def reconnect_blocked_error?(error)
        error.message.include?("SQLite3::CantOpenException") &&
          error.message.include?("PRAGMA journal_mode='wal'")
      end

      # @rbs (Exception) -> bool
      def busy_error?(error)
        cause = error
        while cause
          return true if cause.class.name.match?(/BusyException|BusyError/)

          cause = cause.cause
        end
        false
      end

      # @rbs (Integer) -> void
      def wait_before_busy_retry(attempts)
        LOCK_RETRY_MUTEX.synchronize do
          LOCK_RETRY_CONDITION.wait(
            LOCK_RETRY_MUTEX,
            [ LOCK_RETRY_INTERVAL * (2**(attempts - 1)), MAXIMUM_BUSY_RETRY_INTERVAL ].min
          )
        end
      end

      # The deadline can expire between the check above and this wait, which
      # would otherwise ask for a negative interval.
      # @rbs () -> void
      def wait_before_retry
        interval = [ LOCK_RETRY_INTERVAL, SyncDeadline.remaining ].min
        return unless interval.positive?

        LOCK_RETRY_MUTEX.synchronize do
          LOCK_RETRY_CONDITION.wait(LOCK_RETRY_MUTEX, interval)
        end
      end
    end
  end
end
