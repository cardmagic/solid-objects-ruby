# rbs_inline: enabled

require "action_controller/base"

module SolidObjects
  class ComponentsController < ActionController::Base
    protect_from_forgery with: :exception

    # @rbs () -> void
    def show
      SolidObjects.instrument(:"component.refreshed") { |payload| refresh(payload) }
    end

    private

    # @rbs (Hash[Symbol, untyped]) -> void
    def refresh(payload)
      registration = ComponentRegistration.from_token(
        params.require(:token)
      )
      payload.merge!(registration_payload(registration))
      requested_revision = requested_revision_key
      snapshot = ActorSnapshot.new(registration.reference)
      payload[:instance_id] = snapshot.instance_id
      payload[:revision] = snapshot.revision
      if newer_than_snapshot?(requested_revision, snapshot)
        payload[:outcome] = "conflict"
        return head :conflict
      end

      authorization_context = SolidObjects
        .configuration
        .component_authorization_context
        .call(controller: self)
      rendered = ComponentRenderer.new(
        snapshot:,
        registration:,
        view_context: component_view_context,
        authorization_context:
      ).call
      response.headers["Cache-Control"] = "private, no-store"
      payload[:outcome] = "rendered"
      render html: component_frame(registration, snapshot, rendered)
    rescue Unauthorized
      payload[:outcome] = "unauthorized"
      head :forbidden
    rescue UnknownComponent
      payload[:outcome] = "unknown_component"
      head :not_found
    rescue ActionController::ParameterMissing,
      ArgumentError,
      InvalidComponentToken
      payload[:outcome] = "invalid_token"
      head :bad_request
    end

    # @rbs (ComponentRegistration) -> Hash[Symbol, untyped]
    def registration_payload(registration)
      {
        actor_type: registration.reference.actor_type,
        actor_id: registration.reference.actor_id,
        component_name: registration.component_name,
        component_key: registration.component_key,
        dependencies: registration.dependencies,
        refresh_method: registration.refresh_method
      }
    end

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
      revision = "#{snapshot.instance_id}:#{snapshot.revision}"
      %(<turbo-frame id="#{registration.dom_id}" data-solid-objects-revision="#{revision}" data-solid-objects-refresh="#{registration.refresh_method}">#{rendered}</turbo-frame>).html_safe
    end
  end
end
