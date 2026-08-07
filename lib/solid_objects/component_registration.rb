# rbs_inline: enabled

require "uri"

module SolidObjects
  class ComponentRegistration
    # @rbs @reference: Reference
    # @rbs @component_name: String
    # @rbs @dependencies: Array[String]
    # @rbs @instance_id: Integer
    # @rbs @revision: Integer
    # @rbs @refresh_path: String
    # @rbs @token: String

    attr_reader :reference,
      :component_name,
      :dependencies,
      :instance_id,
      :revision,
      :refresh_path,
      :token

    # @rbs (reference: Reference, component_name: String, dependencies: Array[String], instance_id: Integer, revision: Integer, refresh_path: String, token: String) -> void
    def initialize(
      reference:,
      component_name:,
      dependencies:,
      instance_id:,
      revision:,
      refresh_path:,
      token:
    )
      @reference = reference
      @component_name = component_name
      @dependencies = dependencies.freeze
      @instance_id = instance_id
      @revision = revision
      @refresh_path = refresh_path
      @token = token
    end

    class << self
      # @rbs (reference: Reference, component_name: String, dependencies: Array[String], snapshot: ActorSnapshot, refresh_path: String) -> ComponentRegistration
      def issue(reference:, component_name:, dependencies:, snapshot:, refresh_path:)
        token = ComponentToken.generate(
          reference:,
          component_name:,
          dependencies:,
          instance_id: snapshot.instance_id,
          revision: snapshot.revision,
          refresh_path:
        )
        new(
          reference:,
          component_name:,
          dependencies:,
          instance_id: snapshot.instance_id,
          revision: snapshot.revision,
          refresh_path:,
          token:
        )
      end

      # @rbs (String) -> ComponentRegistration
      def from_token(token)
        payload = ComponentToken.verify(token)
        reference = Reference.new(
          actor_type: payload.fetch("actor_type"),
          actor_id: payload.fetch("actor_id")
        )
        dependencies = payload.fetch("dependencies")
        validate_dependencies!(reference, dependencies)
        new(
          reference:,
          component_name: payload.fetch("component_name"),
          dependencies:,
          instance_id: payload.fetch("instance_id"),
          revision: payload.fetch("revision"),
          refresh_path: payload.fetch("refresh_path"),
          token:
        )
      rescue UnknownActorType, UnknownComponentDependency => error
        raise InvalidComponentToken, error.message
      end

      private

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
