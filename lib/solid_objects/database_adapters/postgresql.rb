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
    end
  end
end
