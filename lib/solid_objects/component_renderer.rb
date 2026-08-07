# rbs_inline: enabled

module SolidObjects
  class ComponentRenderer
    # @rbs @snapshot: ActorSnapshot
    # @rbs @component_name: String
    # @rbs @dependencies: Array[String]
    # @rbs @view_context: untyped
    # @rbs @authorization_context: untyped

    # @rbs (snapshot: ActorSnapshot, component_name: String, dependencies: Array[String], view_context: untyped, authorization_context: untyped) -> void
    def initialize(
      snapshot:,
      component_name:,
      dependencies:,
      view_context:,
      authorization_context:
    )
      @snapshot = snapshot
      @component_name = component_name
      @dependencies = dependencies
      @view_context = view_context
      @authorization_context = authorization_context
    end

    # @rbs () -> untyped
    def call
      dependencies.each { |dependency| authorize_read!(dependency) }
      actor = ComponentView.new(
        snapshot:,
        dependencies:,
        authorization_context:
      )
      view_context.render(
        partial: default_partial,
        locals: {
          actor:,
          authorization_context:
        }
      )
    rescue ActionView::MissingTemplate
      raise UnknownComponent,
        "unknown component #{component_name.inspect} for #{snapshot.reference.actor_type}"
    rescue ActionView::Template::Error => error
      raise error.cause if error.cause.is_a?(SolidObjects::Error)

      raise
    end

    private

    attr_reader :snapshot,
      :component_name,
      :dependencies,
      :view_context,
      :authorization_context

    # @rbs (String) -> void
    def authorize_read!(observable_name)
      authorized = SolidObjects.configuration.authorize_query.call(
        actor_type: snapshot.reference.actor_type,
        actor_id: snapshot.reference.actor_id,
        message_name: observable_name,
        arguments: {},
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor component query is not authorized"
    end

    # @rbs () -> String
    def default_partial
      actor_name = snapshot.actor_class.name
      raise InvalidActor, "anonymous actors cannot render reactive components" unless actor_name

      "actors/#{actor_name.underscore}/#{component_name}"
    end
  end
end
