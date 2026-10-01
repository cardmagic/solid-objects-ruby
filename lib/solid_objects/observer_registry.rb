# rbs_inline: enabled

module SolidObjects
  class ObserverRegistry
    MAXIMUM_OBSERVERS = 1000

    # @rbs @subscriptions: Array[Object]
    # @rbs @mutex: Mutex

    # @rbs () -> void
    def initialize
      @subscriptions = []
      @mutex = Mutex.new
    end

    # @rbs () { (ActiveSupport::Notifications::Event) -> void } -> Proc
    def subscribe(&listener)
      subscription = mutex.synchronize do
        raise ArgumentError, "at most #{MAXIMUM_OBSERVERS} local observers may be registered" if subscriptions.length >= MAXIMUM_OBSERVERS

        ActiveSupport::Notifications.subscribe(/\Asolid_objects\./, &listener).tap { |created| subscriptions << created }
      end
      -> { unsubscribe(subscription) }
    end

    # @rbs () -> void
    def clear
      mutex.synchronize do
        subscriptions.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
        subscriptions.clear
      end
    end

    private

    attr_reader :subscriptions #: Array[Object]
    attr_reader :mutex #: Mutex

    # @rbs (Object) -> void
    def unsubscribe(subscription)
      mutex.synchronize do
        ActiveSupport::Notifications.unsubscribe(subscription)
        subscriptions.delete(subscription)
      end
    end
  end
end
