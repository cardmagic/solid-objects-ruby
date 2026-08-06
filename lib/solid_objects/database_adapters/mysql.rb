# rbs_inline: enabled

module SolidObjects
  module DatabaseAdapters
    class Mysql < DatabaseAdapter
      # @rbs () -> bool
      def supports_skip_locked?
        true
      end

      # @rbs () -> String
      def claim_lock
        "FOR UPDATE SKIP LOCKED"
      end

      # @rbs () -> String
      def current_time_expression
        "CURRENT_TIMESTAMP(6)"
      end

      private

      # @rbs (untyped) { () -> untyped } -> untyped
      def with_transaction_deadline(connection)
        return yield unless SyncDeadline.active?

        previous_lock_timeout = connection.select_value(
          "SELECT @@SESSION.innodb_lock_wait_timeout"
        ).to_i
        previous_execution_timeout = connection.select_value(
          "SELECT @@SESSION.max_execution_time"
        ).to_i
        connection.execute(
          "SET SESSION innodb_lock_wait_timeout = #{SyncDeadline.remaining_seconds}"
        )
        connection.execute(
          "SET SESSION max_execution_time = #{SyncDeadline.remaining_milliseconds}"
        )
        yield
      ensure
        if previous_lock_timeout
          connection.execute(
            "SET SESSION innodb_lock_wait_timeout = #{previous_lock_timeout}"
          )
        end
        if previous_execution_timeout
          connection.execute(
            "SET SESSION max_execution_time = #{previous_execution_timeout}"
          )
        end
      end

      # @rbs (Exception) -> bool
      def deadline_error?(error)
        return false unless SyncDeadline.active?
        return true if error.is_a?(ActiveRecord::LockWaitTimeout)

        cause = error
        while cause
          return true if cause.respond_to?(:error_number) && cause.error_number == 3024

          cause = cause.cause
        end
        false
      end
    end
  end
end
