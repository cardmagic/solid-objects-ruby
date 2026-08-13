# rbs_inline: enabled

module SolidObjects
  class ComponentRenderer
    # @rbs @snapshot: ActorSnapshot
    # @rbs @registration: ComponentRegistration
    # @rbs @view_context: untyped
    # @rbs @authorization_context: untyped

    # @rbs (snapshot: ActorSnapshot, registration: ComponentRegistration, view_context: untyped, authorization_context: untyped) -> void
    def initialize(
      snapshot:,
      registration:,
      view_context:,
      authorization_context:
    )
      @snapshot = snapshot
      @registration = registration
      @view_context = view_context
      @authorization_context = authorization_context
    end

    # @rbs () -> untyped
    def call
      [ registration.component_name, *registration.dependencies ].uniq.each do |authorization_name|
        authorize_read!(authorization_name)
      end
      actor = ComponentView.new(
        snapshot:,
        dependencies: registration.dependencies,
        authorization_context:
      )
      view_context.render(
        partial: default_partial,
        formats: [ :html ],
        locals: registration.locals.transform_keys(&:to_sym).merge(
          actor:,
          authorization_context:,
          component_key: registration.component_key
        )
      )
    rescue ActionView::MissingTemplate
      raise UnknownComponent,
        "unknown component #{registration.component_name.inspect} for #{snapshot.reference.actor_type}"
    rescue ActionView::Template::Error => error
      raise error.cause if error.cause.is_a?(SolidObjects::Error)

      raise
    end

    private

    attr_reader :snapshot,
      :registration,
      :view_context,
      :authorization_context

    # @rbs (String) -> void
    def authorize_read!(observable_name)
      authorized = SolidObjects.configuration.authorize_query.call(
        actor_type: snapshot.reference.actor_type,
        actor_id: snapshot.reference.actor_id,
        operation: observable_name,
        arguments: registration.authorization_arguments,
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor component query is not authorized"
    end

    # @rbs () -> String
    def default_partial
      actor_name = snapshot.actor_class.name
      raise InvalidActor, "anonymous actors cannot render reactive components" unless actor_name

      "actors/#{actor_name.underscore}/#{registration.component_name}"
    end
  end
end
