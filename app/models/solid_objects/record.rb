# rbs_inline: enabled

module SolidObjects
  class Record < ActiveRecord::Base
    self.abstract_class = true

    class << self
      # @rbs () -> void
      def configure_connection
        connection_configuration = SolidObjects.configuration.connects_to
        return unless connection_configuration

        connects_to(**connection_configuration)
      end
    end
  end
end
