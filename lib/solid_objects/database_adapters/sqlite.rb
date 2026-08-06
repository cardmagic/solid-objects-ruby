# rbs_inline: enabled

module SolidObjects
  module DatabaseAdapters
    class Sqlite < DatabaseAdapter
      # @rbs () -> String
      def current_time_expression
        "STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW')"
      end
    end
  end
end
