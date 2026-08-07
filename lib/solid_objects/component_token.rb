# rbs_inline: enabled

require "active_support/message_verifier"

module SolidObjects
  module ComponentToken
    PURPOSE = "solid_objects.actor_component"
    MAXIMUM_TOKEN_BYTES = 16_384
    MAXIMUM_DEPENDENCIES = 50

    module_function

    # @rbs (reference: Reference, component_name: String, dependencies: Array[String], instance_id: Integer, revision: Integer, refresh_path: String) -> String
    def generate(
      reference:,
      component_name:,
      dependencies:,
      instance_id:,
      revision:,
      refresh_path:
    )
      payload = {
        "actor_type" => reference.actor_type,
        "actor_id" => reference.actor_id,
        "component_name" => component_name,
        "dependencies" => dependencies,
        "instance_id" => instance_id,
        "revision" => revision,
        "refresh_path" => refresh_path
      }
      validate_payload!(payload)
      verifier.generate(payload, purpose: PURPOSE).tap do |token|
        raise InvalidComponentToken, "component token is too large" if token.bytesize > MAXIMUM_TOKEN_BYTES
      end
    end

    # @rbs (String) -> Hash[String, untyped]
    def verify(token)
      unless token.is_a?(String) && token.bytesize <= MAXIMUM_TOKEN_BYTES
        raise InvalidComponentToken, "invalid actor component token"
      end

      payload = verifier.verified(token, purpose: PURPOSE)
      validate_payload!(payload)
      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise InvalidComponentToken, "invalid actor component token"
    end

    # @rbs (Hash[String, untyped]) -> Hash[String, untyped]
    def validate_payload!(payload)
      unless payload.is_a?(Hash) &&
          payload["actor_type"].is_a?(String) &&
          payload["actor_id"].is_a?(String) &&
          payload["component_name"].is_a?(String) &&
          payload["dependencies"].is_a?(Array) &&
          payload["instance_id"].is_a?(Integer) &&
          payload["revision"].is_a?(Integer) &&
          payload["refresh_path"].is_a?(String)
        raise InvalidComponentToken, "invalid actor component token"
      end

      validate_component_name!(payload.fetch("component_name"))
      validate_dependencies!(payload.fetch("dependencies"))
      validate_revision!(
        payload.fetch("instance_id"),
        payload.fetch("revision")
      )
      validate_refresh_path!(payload.fetch("refresh_path"))
      payload
    end
    private_class_method :validate_payload!

    # @rbs (String) -> void
    def validate_component_name!(component_name)
      return if component_name.match?(/\A[a-zA-Z0-9_]+\z/)

      raise InvalidComponentToken, "invalid actor component name"
    end
    private_class_method :validate_component_name!

    # @rbs (Array[untyped]) -> void
    def validate_dependencies!(dependencies)
      valid = dependencies.any? &&
        dependencies.length <= MAXIMUM_DEPENDENCIES &&
        dependencies.uniq.length == dependencies.length &&
        dependencies.all? { |dependency| dependency.is_a?(String) && dependency.match?(/\A[a-zA-Z0-9_]+\z/) }
      return if valid

      raise InvalidComponentToken, "invalid actor component dependencies"
    end
    private_class_method :validate_dependencies!

    # @rbs (Integer, Integer) -> void
    def validate_revision!(instance_id, revision)
      return unless instance_id.negative? || revision.negative?

      raise InvalidComponentToken, "invalid actor component revision"
    end
    private_class_method :validate_revision!

    # @rbs (String) -> void
    def validate_refresh_path!(refresh_path)
      valid = refresh_path.bytesize <= 2_048 &&
        refresh_path.start_with?("/") &&
        !refresh_path.start_with?("//") &&
        !refresh_path.include?("\0") &&
        !refresh_path.include?("?") &&
        !refresh_path.include?("#")
      return if valid

      raise InvalidComponentToken, "invalid actor component refresh path"
    end
    private_class_method :validate_refresh_path!

    # @rbs () -> ActiveSupport::MessageVerifier
    def verifier
      ActiveSupport::MessageVerifier.new(
        signing_secret,
        digest: "SHA256",
        serializer: JSON
      )
    end
    private_class_method :verifier

    # @rbs () -> String
    def signing_secret
      configured_secret = SolidObjects.configuration.stream_signing_secret
      return configured_secret if configured_secret

      if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        return Rails.application.key_generator.generate_key(PURPOSE, 64)
      end

      raise ArgumentError, "configure stream_signing_secret outside a Rails application"
    end
    private_class_method :signing_secret
  end
end
