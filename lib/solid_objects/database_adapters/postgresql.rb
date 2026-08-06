# rbs_inline: enabled

module SolidObjects
  module DatabaseAdapters
    class Postgresql < DatabaseAdapter
      # @rbs () -> bool
      def supports_skip_locked?
        true
      end

      # @rbs () -> String
      def claim_lock
        "FOR UPDATE SKIP LOCKED"
      end

      private

      # @rbs (untyped) -> void
      def configure_transaction_deadline(connection)
        return unless SyncDeadline.active?

        connection.execute(
          "SET LOCAL lock_timeout = #{SyncDeadline.remaining_milliseconds}"
        )
        connection.execute(
          "SET LOCAL statement_timeout = #{SyncDeadline.remaining_milliseconds}"
        )
      end

      # @rbs (Exception) -> bool
      def deadline_error?(error)
        return false unless SyncDeadline.active?
        return true if error.is_a?(ActiveRecord::LockWaitTimeout)

        cause = error
        while cause
          result = cause.respond_to?(:result) ? cause.result : nil
          return true if result&.error_field(PG::Result::PG_DIAG_SQLSTATE) == "57014"

          cause = cause.cause
        end
        false
      end
    end
  end
end
