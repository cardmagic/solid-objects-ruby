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
    end
  end
end
