# rbs_inline: enabled

require "action_controller/base"

module SolidObjects
  class ComponentsController < ActionController::Base
    protect_from_forgery with: :exception

    BATCH_LIMIT = 50

    # @rbs () -> void
    def show
      SolidObjects.instrument(:"component.refreshed") { |payload| refresh(payload) }
    end

    # @rbs () -> void
    def batch
      SolidObjects.instrument(:"component.batch_refreshed") { |payload| refresh_batch(payload) }
    end

    private

    # @rbs (Hash[Symbol, untyped]) -> void
    def refresh_batch(payload)
      tokens = Array(params.require(:tokens))
      raise ActionController::ParameterMissing, :tokens if tokens.empty?
      raise ArgumentError if tokens.length > BATCH_LIMIT

      registrations = tokens.map { |token| ComponentRegistration.from_token(token) }
      validate_single_batch!(registrations)
      requested_revision = requested_revision_key
      snapshot = ActorSnapshot.new(registrations.first.reference)
      payload.merge!(
        actor_type: snapshot.reference.actor_type,
        actor_id: snapshot.reference.actor_id,
        batch: registrations.first.batch,
        components: registrations.map(&:component_name),
        instance_id: snapshot.instance_id,
        revision: snapshot.revision
      )
      if newer_than_snapshot?(requested_revision, snapshot)
        payload[:outcome] = "conflict"
        return head :conflict
      end

      authorization_context = component_authorization_context(registrations)
      frames = registrations.map do |registration|
        rendered = ComponentRenderer.new(
          snapshot:,
          registration:,
          view_context: component_view_context,
          authorization_context:
        ).call
        {
          "target" => registration.dom_id,
          "revision" => "#{snapshot.instance_id}:#{snapshot.revision}",
          "refresh_method" => registration.refresh_method,
          "html" => component_frame(registration, snapshot, rendered)
        }
      end
      response.headers["Cache-Control"] = "private, no-store"
      payload[:outcome] = "rendered"
      render json: {
        "actor_type" => snapshot.reference.actor_type,
        "actor_id" => snapshot.reference.actor_id,
        "batch" => registrations.first.batch,
        "instance_id" => snapshot.instance_id,
        "revision" => snapshot.revision,
        "frames" => frames
      }
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

    # @rbs (Array[ComponentRegistration]) -> void
    def validate_single_batch!(registrations)
      first = registrations.first
      raise ArgumentError unless first.batch
      return if registrations.all? do |registration|
        registration.batch == first.batch &&
          registration.reference.actor_type == first.reference.actor_type &&
          registration.reference.actor_id == first.reference.actor_id
      end

      raise ArgumentError
    end

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

      authorization_context = component_authorization_context([ registration ])
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

    # Callbacks written before batching accept only `controller:`. Those keep
    # working; a callback that also accepts `registrations:` receives one
    # registration for a single refresh and all of them for a batch.
    # @rbs (Array[ComponentRegistration]) -> untyped
    def component_authorization_context(registrations)
      callable = SolidObjects.configuration.component_authorization_context
      return callable.call(controller: self) unless accepts_registrations?(callable)

      callable.call(controller: self, registrations:)
    end

    # @rbs (untyped) -> bool
    def accepts_registrations?(callable)
      return false unless callable.respond_to?(:parameters)

      callable.parameters.any? do |type, name|
        type == :keyrest || (%i[key keyreq].include?(type) && name == :registrations)
      end
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
