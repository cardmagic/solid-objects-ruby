# rbs_inline: enabled

module SolidObjects
  class ActorView
    # @rbs @reference: Reference
    # @rbs @view_context: untyped
    # @rbs @authorization_context: untyped
    # @rbs @snapshot: ActorSnapshot
    # @rbs @component_registrations: Array[ComponentRegistration]
    # @rbs @observable_names: Array[String]

    attr_reader :reference

    # @rbs (reference: Reference, view_context: untyped, authorization_context: untyped) -> void
    def initialize(reference:, view_context:, authorization_context:)
      @reference = reference
      @view_context = view_context
      @authorization_context = authorization_context
      @snapshot = ActorSnapshot.new(reference)
      @component_registrations = []
      @observable_names = []
    end

    # @rbs (Symbol | String) -> untyped
    def value(name)
      observable_name = name.to_sym
      handler = snapshot.actor_class.definition.observables[observable_name]
      raise UnknownMessage, "unknown observable #{name.inspect}" unless handler

      authorize_read!(observable_name)
      value = snapshot.observable_value(observable_name)
      observable_names << observable_name.to_s unless observable_names.include?(observable_name.to_s)
      view_context.content_tag(
        :span,
        display_value(value),
        id: DomIdentity.observable(reference, observable_name)
      )
    end

    # @rbs (Symbol | String, ?observes: Symbol | String | Array[Symbol | String]?, ?partial: String?, ?key: untyped, ?locals: Hash[untyped, untyped], ?refresh: String | Symbol, ?batch: untyped) -> untyped
    def component(
      name,
      observes: nil,
      partial: nil,
      key: nil,
      locals: {},
      refresh: :replace,
      batch: nil
    )
      component_name = normalized_component_name(name)
      unless observes
        validate_static_options!(key:, locals:, refresh:, batch:)
        return static_component(component_name, partial:)
      end
      if partial
        raise ArgumentError,
          "reactive components resolve partials by actor and component name"
      end

      dependencies = normalized_dependencies(observes)
      validate_dependencies!(dependencies)
      refresh_path = component_path_resolver.call(view_context:)
      registration = ComponentRegistration.issue(
        reference:,
        component_name:,
        component_key: key,
        dependencies:,
        locals:,
        refresh_method: refresh,
        snapshot:,
        refresh_path:,
        batch: batch&.to_s
      )
      ensure_unique_component!(registration)
      rendered = ComponentRenderer.new(
        snapshot:,
        registration:,
        view_context:,
        authorization_context:
      ).call
      component_registrations << registration
      view_context.content_tag(
        :"turbo-frame",
        rendered,
        id: registration.dom_id,
        data: {
          solid_objects_revision: "#{snapshot.instance_id}:#{snapshot.revision}",
          solid_objects_refresh: registration.refresh_method
        }
      )
    end

    # @rbs () -> Array[String]
    def component_tokens
      component_registrations.map(&:token)
    end

    # @rbs () -> Array[String]
    def scalar_observable_names
      observable_names.dup
    end

    # @rbs () -> bool
    def batched_components?
      component_registrations.any?(&:batch)
    end

    # @rbs () -> bool
    def morph_components?
      component_registrations.any?(&:morph?)
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

    attr_reader :view_context,
      :authorization_context,
      :snapshot,
      :component_registrations,
      :observable_names

    # @rbs (String, partial: String?) -> untyped
    def static_component(component_name, partial:)
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

    # @rbs (Symbol | String | Array[Symbol | String]) -> Array[String]
    def normalized_dependencies(observes)
      dependencies = Array(observes).map(&:to_s).uniq
      if dependencies.empty?
        raise ArgumentError, "reactive components require at least one observable"
      end

      dependencies
    end

    # @rbs (Array[String]) -> void
    def validate_dependencies!(dependencies)
      unknown = dependencies.find do |dependency|
        !snapshot.actor_class.definition.observables.key?(dependency.to_sym)
      end
      return unless unknown

      raise UnknownComponentDependency,
        "unknown observable dependency #{unknown.inspect} for #{reference.actor_type}"
    end

    # @rbs (ComponentRegistration) -> void
    def ensure_unique_component!(registration)
      return unless component_registrations.any? do |existing_registration|
        existing_registration.dom_id == registration.dom_id
      end

      raise ArgumentError,
        "component #{registration.component_name.inspect} with key " \
          "#{registration.component_key.inspect} is already rendered in this solid_object scope"
    end

    # @rbs (key: untyped, locals: Hash[untyped, untyped], refresh: String | Symbol, batch: untyped) -> void
    def validate_static_options!(key:, locals:, refresh:, batch:)
      return if key.nil? && locals.empty? && refresh.to_s == "replace" && batch.nil?

      raise ArgumentError,
        "key, locals, and refresh require an observable component"
    end

    # @rbs () -> Proc | ComponentPathResolver
    def component_path_resolver
      SolidObjects.configuration.component_path_resolver ||
        ComponentPathResolver.new
    end

    # @rbs (String) -> String
    def default_partial(component_name)
      actor_name = snapshot.actor_class.name
      raise InvalidActor, "anonymous actors must provide an explicit component partial" unless actor_name

      "actors/#{actor_name.underscore}/#{component_name}"
    end
  end
end
