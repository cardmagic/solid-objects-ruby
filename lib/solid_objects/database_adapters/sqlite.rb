# rbs_inline: enabled

module SolidObjects
  module DatabaseAdapters
    class Sqlite < DatabaseAdapter
      # @rbs () -> String
      def current_time_expression
        "STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW')"
      end

      private

      # @rbs (untyped) { () -> untyped } -> untyped
      def with_transaction_deadline(connection)
        return yield unless SyncDeadline.active?

        previous_timeout = connection.select_value("PRAGMA busy_timeout").to_i
        connection.execute(
          "PRAGMA busy_timeout = #{SyncDeadline.remaining_milliseconds}"
        )
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
    end
  end
end
