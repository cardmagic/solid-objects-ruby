# rbs_inline: enabled

module SolidObjects
  class ComponentPathResolver
    # @rbs (view_context: untyped) -> String
    def call(view_context:)
      unless mounted?
        raise UnsupportedComponentRendering,
          "reactive components require the SolidObjects::Engine to be mounted in the host routes"
      end

      SolidObjects::Engine.routes.url_helpers.components_path
    end

    private

    # @rbs () -> bool
    def mounted?
      return false unless defined?(Rails) && Rails.application

      Rails.application.routes.routes.any? do |route|
        route.app.respond_to?(:app) &&
          route.app.app.equal?(SolidObjects::Engine)
      end
    end
  end
end
