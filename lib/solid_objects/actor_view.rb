# rbs_inline: enabled

module SolidObjects
  class ActorView
    # @rbs @reference: Reference
    # @rbs @view_context: untyped
    # @rbs @authorization_context: untyped
    # @rbs @snapshot: ActorSnapshot

    attr_reader :reference

    # @rbs (reference: Reference, view_context: untyped, authorization_context: untyped) -> void
    def initialize(reference:, view_context:, authorization_context:)
      @reference = reference
      @view_context = view_context
      @authorization_context = authorization_context
      @snapshot = ActorSnapshot.new(reference)
    end

    # @rbs (Symbol | String) -> untyped
    def value(name)
      observable_name = name.to_sym
      handler = snapshot.actor_class.definition.observables[observable_name]
      raise UnknownMessage, "unknown observable #{name.inspect}" unless handler

      authorize_read!(observable_name)
      value = snapshot.observable_values.fetch(observable_name.to_s)
      view_context.content_tag(
        :span,
        display_value(value),
        id: DomIdentity.observable(reference, observable_name)
      )
    end

    # @rbs (Symbol | String, ?partial: String?) -> untyped
    def component(name, partial: nil)
      component_name = normalized_component_name(name)
      authorize_read!(component_name)
      rendered = view_context.render(
        partial: partial || default_partial(component_name),
        locals: { actor: self }
      )
      view_context.content_tag(
        :div,
        rendered,
        id: DomIdentity.component(reference, component_name)
      )
    end

    # @rbs () -> State
    def state
      snapshot.actor.state
    end

    # @rbs (Symbol, *untyped, **untyped) -> untyped
    def method_missing(name, *arguments, **keywords)
      return value(name) if arguments.empty? && keywords.empty? && observable?(name)

      super
    end

    # @rbs (Symbol, bool) -> bool
    def respond_to_missing?(name, include_private = false)
      observable?(name) || super
    end

    private

    attr_reader :view_context, :authorization_context, :snapshot

    # @rbs (Symbol | String) -> void
    def authorize_read!(name)
      authorized = SolidObjects.configuration.authorize_query.call(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        message_name: name.to_s,
        arguments: {},
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor state query is not authorized"
    end

    # @rbs (Symbol | String) -> bool
    def observable?(name)
      snapshot.actor_class.definition.observables.key?(name.to_sym)
    end

    # @rbs (untyped) -> String
    def display_value(value)
      return value if value.is_a?(String)
      return value.to_s if value.is_a?(Numeric) || value == true || value == false
      return "" if value.nil?

      JSON.generate(value)
    end

    # @rbs (Symbol | String) -> String
    def normalized_component_name(name)
      component_name = name.to_s
      unless component_name.match?(/\A[a-zA-Z0-9_]+\z/)
        raise ArgumentError, "component names may contain only letters, digits, and underscores"
      end

      component_name
    end

    # @rbs (String) -> String
    def default_partial(component_name)
      actor_name = snapshot.actor_class.name
      raise InvalidActor, "anonymous actors must provide an explicit component partial" unless actor_name

      "actors/#{actor_name.underscore}/#{component_name}"
    end
  end
end
