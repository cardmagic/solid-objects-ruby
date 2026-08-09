# rbs_inline: enabled

require "uri"

module SolidObjects
  class ComponentRegistration
    # @rbs @reference: Reference
    # @rbs @component_name: String
    # @rbs @component_key: String | Integer?
    # @rbs @batch: String?
    # @rbs @dependencies: Array[String]
    # @rbs @locals: Hash[String, untyped]
    # @rbs @refresh_method: String
    # @rbs @instance_id: Integer
    # @rbs @revision: Integer
    # @rbs @refresh_path: String
    # @rbs @token: String

    attr_reader :reference,
      :component_name,
      :component_key,
      :batch,
      :dependencies,
      :locals,
      :refresh_method,
      :instance_id,
      :revision,
      :refresh_path,
      :token

    # @rbs (reference: Reference, component_name: String, component_key: String | Integer?, dependencies: Array[String], locals: Hash[String, untyped], refresh_method: String, instance_id: Integer, revision: Integer, refresh_path: String, token: String) -> void
    def initialize(
      reference:,
      component_name:,
      component_key:,
      dependencies:,
      locals:,
      refresh_method:,
      instance_id:,
      revision:,
      refresh_path:,
      token:,
      batch: nil
    )
      @reference = reference
      @batch = batch
      @component_name = component_name
      @component_key = component_key
      @dependencies = dependencies.freeze
      @locals = Serialization.readonly_copy(locals)
      @refresh_method = refresh_method
      @instance_id = instance_id
      @revision = revision
      @refresh_path = refresh_path
      @token = token
    end

    class << self
      # @rbs (reference: Reference, component_name: String, component_key: untyped, dependencies: Array[String], locals: Hash[untyped, untyped], refresh_method: String | Symbol, snapshot: ActorSnapshot, refresh_path: String) -> ComponentRegistration
      def issue(
        reference:,
        component_name:,
        component_key:,
        dependencies:,
        locals:,
        refresh_method:,
        snapshot:,
        refresh_path:,
        batch: nil
      )
        token = ComponentToken.generate(
          reference:,
          component_name:,
          component_key:,
          dependencies:,
          locals:,
          refresh_method:,
          batch:,
          instance_id: snapshot.instance_id,
          revision: snapshot.revision,
          refresh_path:
        )
        build(ComponentToken.verify(token), token:)
      end

      # @rbs (String) -> ComponentRegistration
      def from_token(token)
        payload = ComponentToken.verify(token)
        build(payload, token:)
      rescue UnknownActorType, UnknownComponentDependency => error
        raise InvalidComponentToken, error.message
      end

      private

      # @rbs (Hash[String, untyped], token: String) -> ComponentRegistration
      def build(payload, token:)
        reference = Reference.new(
          actor_type: payload.fetch("actor_type"),
          actor_id: payload.fetch("actor_id")
        )
        dependencies = payload.fetch("dependencies")
        validate_dependencies!(reference, dependencies)
        new(
          reference:,
          component_name: payload.fetch("component_name"),
          component_key: payload["component_key"],
          batch: payload["batch"],
          dependencies:,
          locals: payload.fetch("locals"),
          refresh_method: payload.fetch("refresh_method"),
          instance_id: payload.fetch("instance_id"),
          revision: payload.fetch("revision"),
          refresh_path: payload.fetch("refresh_path"),
          token:
        )
      end

      # @rbs (Reference, Array[String]) -> void
      def validate_dependencies!(reference, dependencies)
        actor_class = SolidObjects.registry.fetch(reference.actor_type)
        observables = actor_class.definition.observables
        unknown = dependencies.find do |dependency|
          !observables.key?(dependency.to_sym)
        end
        return unless unknown

        raise UnknownComponentDependency,
          "unknown observable dependency #{unknown.inspect} for #{reference.actor_type}"
      end
    end

    # @rbs () -> Array[Integer]
    def revision_key
      [ instance_id, revision ]
    end

    # @rbs () -> String
    def dom_id
      DomIdentity.component(
        reference,
        component_name,
        key: component_key
      )
    end

    # @rbs () -> bool
    def morph?
      refresh_method == "morph"
    end

    # @rbs () -> Hash[String, untyped]
    def authorization_arguments
      return locals unless component_key

      locals.merge("component_key" => component_key).freeze
    end

    # @rbs (Array[ComponentRegistration], Integer, Integer) -> String
    def batch_refresh_url(registrations, instance_id, revision)
      query = URI.encode_www_form(
        [
          [ "instance_id", instance_id ],
          [ "revision", revision ],
          *registrations.map { |registration| [ "tokens[]", registration.token ] }
        ]
      )
      "#{refresh_path}/batch?#{query}"
    end

    # @rbs (Integer, Integer) -> String
    def refresh_url(instance_id, revision)
      query = URI.encode_www_form(
        token:,
        instance_id:,
        revision:
      )
      "#{refresh_path}?#{query}"
    end
  end
end
