# rbs_inline: enabled

module SolidObjects
  module Instrumentation
    # @rbs (Symbol, **untyped) { (Hash[Symbol, untyped]) -> untyped } -> untyped
    def instrument(event, **payload, &block)
      ActiveSupport::Notifications.instrument("solid_objects.#{event}", payload, &block)
    end

    # @rbs (Symbol, **untyped) -> void
    def instrument_after_commit(event, **payload)
      instrument(event, **payload)
    rescue => error
      report_instrumentation_failure(event, error)
    end

    private

    # @rbs (Symbol, Exception) -> void
    def report_instrumentation_failure(event, error)
      instrument(
        :"instrumentation.failed",
        instrumentation_event: "solid_objects.#{event}",
        error_class: error.class.name
      )
    rescue => failure
      log_instrumentation_failure(event, failure)
    end

    # @rbs (Symbol, Exception) -> void
    def log_instrumentation_failure(event, error)
      SolidObjects.configuration.logger.error(
        {
          event: "solid_objects.instrumentation.failed",
          instrumentation_event: "solid_objects.#{event}",
          error_class: error.class.name
        }
      )
    rescue
      nil
    end
  end
end
