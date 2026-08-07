# rbs_inline: enabled

module SolidObjects
  module DatabaseAdapters
    class Sqlite < DatabaseAdapter
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

        yield_before_retry
        retry
      rescue => error
        raise unless deadline_error?(error)

        if SyncDeadline.expired?
          raise DatabaseDeadlineExceeded,
            "database lock wait exceeded the synchronous invocation deadline",
            cause: error
        end

        yield_before_retry
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

        previous_timeout = connection.select_value("PRAGMA busy_timeout").to_i
        connection.execute("PRAGMA busy_timeout = 0")
        yield
      ensure
        connection.execute("PRAGMA busy_timeout = #{previous_timeout}") if previous_timeout
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
      def yield_before_retry
        Thread.pass
      end
    end
  end
end
