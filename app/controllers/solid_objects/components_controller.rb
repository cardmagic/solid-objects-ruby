# rbs_inline: enabled

require "action_controller/base"

module SolidObjects
  class ComponentsController < ActionController::Base
    protect_from_forgery with: :exception

    # @rbs () -> void
    def show
      registration = ComponentRegistration.from_token(
        params.require(:token)
      )
      requested_revision = requested_revision_key
      snapshot = ActorSnapshot.new(registration.reference)
      return head :conflict if newer_than_snapshot?(requested_revision, snapshot)

      authorization_context = SolidObjects
        .configuration
        .component_authorization_context
        .call(controller: self)
      rendered = ComponentRenderer.new(
        snapshot:,
        component_name: registration.component_name,
        dependencies: registration.dependencies,
        view_context: component_view_context,
        authorization_context:
      ).call
      response.headers["Cache-Control"] = "private, no-store"
      render html: component_frame(registration, snapshot, rendered)
    rescue Unauthorized
      head :forbidden
    rescue UnknownComponent
      head :not_found
    rescue ActionController::ParameterMissing,
      ArgumentError,
      InvalidComponentToken
      head :bad_request
    end

    private

    # @rbs () -> Array[Integer]
    def requested_revision_key
      instance_id = Integer(params.fetch(:instance_id), 10)
      revision = Integer(params.fetch(:revision), 10)
      raise ArgumentError if instance_id.negative? || revision.negative?

      [ instance_id, revision ]
    end

    # @rbs (Array[Integer], ActorSnapshot) -> bool
    def newer_than_snapshot?(requested_revision, snapshot)
      (requested_revision <=> [ snapshot.instance_id, snapshot.revision ]) == 1
    end

    # @rbs () -> untyped
    def component_view_context
      if defined?(Rails) && Rails.application
        prepend_view_path(*Rails.application.paths["app/views"].existent)
      end

      view_context.tap do |context|
        context.extend(Rails.application.helpers) if defined?(Rails) && Rails.application
      end
    end

    # @rbs (ComponentRegistration, ActorSnapshot, untyped) -> String
    def component_frame(registration, snapshot, rendered)
      target = DomIdentity.component(
        registration.reference,
        registration.component_name
      )
      revision = "#{snapshot.instance_id}:#{snapshot.revision}"
      %(<turbo-frame id="#{target}" data-solid-objects-revision="#{revision}">#{rendered}</turbo-frame>).html_safe
    end
  end
end
