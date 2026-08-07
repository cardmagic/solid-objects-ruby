# rbs_inline: enabled

module SolidObjects
  module DatabaseAdapters
    class Sqlite < DatabaseAdapter
      LOCK_RETRY_INTERVAL = 0.001
      LOCK_RETRY_MUTEX = Thread::Mutex.new
      LOCK_RETRY_CONDITION = Thread::ConditionVariable.new

      # @rbs () -> String
      def current_time_expression
        "STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW')"
      end

      # @rbs () { () -> untyped } -> untyped
      def transaction(&block)
        return super unless SyncDeadline.active?

        with_lock_retry { super }
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

        busy_wait = suspend_busy_wait(connection)
        begin
          yield
        ensure
          restore_busy_wait(connection, busy_wait)
        end
      end

      # @rbs (untyped) -> Hash[Symbol, untyped]
      def suspend_busy_wait(connection)
        busy_wait = {
          pragma_timeout: connection.select_value("PRAGMA busy_timeout").to_i,
          handler_timeout: configured_busy_handler_timeout(connection)
        }
        connection.execute("PRAGMA busy_timeout = 0")
        busy_wait
      end

      # @rbs (untyped, Hash[Symbol, untyped]) -> void
      def restore_busy_wait(connection, busy_wait)
        handler_timeout = busy_wait.fetch(:handler_timeout)
        pragma_timeout = busy_wait.fetch(:pragma_timeout)
        if handler_timeout && pragma_timeout.zero?
          connection.raw_connection.busy_handler_timeout = handler_timeout
          return
        end

        connection.execute("PRAGMA busy_timeout = #{pragma_timeout}")
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

        cause = error
        while cause
          return true if cause.class.name.match?(/BusyException|BusyError/)

          cause = cause.cause
        end
        false
      end

      # @rbs () -> void
      def wait_before_retry
        LOCK_RETRY_MUTEX.synchronize do
          LOCK_RETRY_CONDITION.wait(
            LOCK_RETRY_MUTEX,
            [ LOCK_RETRY_INTERVAL, SyncDeadline.remaining ].min
          )
        end
      end
    end
  end
end
