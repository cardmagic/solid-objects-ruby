# rbs_inline: enabled

module SolidObjects
  module LogSubscriber
    class << self
      # @rbs () -> void
      def install
        return if @subscription

        @subscription = ActiveSupport::Notifications.subscribe(/\Asolid_objects\./) do |event|
          SolidObjects.configuration.logger.info(
            {
              event: event.name,
              duration_ms: event.duration.round(2)
            }.merge(event.payload)
          )
        end
      end

      # @rbs () -> void
      def uninstall
        return unless @subscription

        ActiveSupport::Notifications.unsubscribe(@subscription)
        @subscription = nil
      end
    end
  end
end
