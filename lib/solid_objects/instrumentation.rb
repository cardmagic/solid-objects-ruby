# rbs_inline: enabled

module SolidObjects
  module Instrumentation
    # @rbs (Symbol, **untyped) { (Hash[Symbol, untyped]) -> untyped } -> untyped
    def instrument(event, **payload, &block)
      ActiveSupport::Notifications.instrument("solid_objects.#{event}", payload, &block)
    end
  end
end
