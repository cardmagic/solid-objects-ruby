# rbs_inline: enabled

require "active_support/message_verifier"

module SolidObjects
  module ComponentToken
    PURPOSE = "solid_objects.actor_component"
    MAXIMUM_TOKEN_BYTES = 16_384
    MAXIMUM_DEPENDENCIES = 50
    MAXIMUM_LOCALS = 50
    MAXIMUM_COMPONENT_KEY_BYTES = 512
    MAXIMUM_BATCH_BYTES = 64
    REFRESH_METHODS = %w[replace morph].freeze
    RESERVED_LOCALS = %w[actor authorization_context component_key].freeze
    RUBY_KEYWORDS = %w[
      alias and begin break case class def defined do else elsif end ensure
      false for if in module next nil not or redo rescue retry return self
      super then true undef unless until when while yield
    ].freeze

    module_function

    # @rbs (reference: Reference, component_name: String, dependencies: Array[String], instance_id: Integer, revision: Integer, refresh_path: String, ?component_key: untyped, ?locals: Hash[untyped, untyped], ?refresh_method: String | Symbol) -> String
    def generate(
      reference:,
      component_name:,
      dependencies:,
      instance_id:,
      revision:,
      refresh_path:,
      component_key: nil,
      locals: {},
      refresh_method: "replace",
      batch: nil
    )
      payload = {
        "actor_type" => reference.actor_type,
        "actor_id" => reference.actor_id,
        "component_name" => component_name,
        "component_key" => Serialization.dump(component_key),
        "batch" => batch&.to_s,
        "dependencies" => dependencies,
        "locals" => Serialization.dump(locals),
        "refresh_method" => refresh_method.to_s,
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
      apply_defaults!(payload)
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
          payload["locals"].is_a?(Hash) &&
          payload["refresh_method"].is_a?(String) &&
          payload["instance_id"].is_a?(Integer) &&
          payload["revision"].is_a?(Integer) &&
          payload["refresh_path"].is_a?(String)
        raise InvalidComponentToken, "invalid actor component token"
      end

      validate_component_name!(payload.fetch("component_name"))
      validate_component_key!(payload["component_key"])
      validate_batch!(payload["batch"])
      validate_dependencies!(payload.fetch("dependencies"))
      validate_locals!(payload.fetch("locals"))
      validate_refresh_method!(payload.fetch("refresh_method"))
      validate_revision!(
        payload.fetch("instance_id"),
        payload.fetch("revision")
      )
      validate_refresh_path!(payload.fetch("refresh_path"))
      payload
    end
    private_class_method :validate_payload!

    # @rbs (Hash[String, untyped]?) -> void
    def apply_defaults!(payload)
      return unless payload.is_a?(Hash)

      payload["component_key"] = nil unless payload.key?("component_key")
      payload["batch"] = nil unless payload.key?("batch")
      payload["locals"] = {} unless payload.key?("locals")
      payload["refresh_method"] = "replace" unless payload.key?("refresh_method")
    end
    private_class_method :apply_defaults!

    # @rbs (String) -> void
    def validate_component_name!(component_name)
      return if component_name.match?(/\A[a-zA-Z0-9_]+\z/)

      raise InvalidComponentToken, "invalid actor component name"
    end
    private_class_method :validate_component_name!

    # @rbs (untyped) -> void
    def validate_component_key!(component_key)
      return if component_key.nil?
      return if component_key.is_a?(Integer)
      if component_key.is_a?(String) &&
          component_key.bytesize.positive? &&
          component_key.bytesize <= MAXIMUM_COMPONENT_KEY_BYTES
        return
      end

      raise InvalidComponentToken, "invalid actor component key"
    end
    private_class_method :validate_component_key!

    # @rbs (untyped) -> void
    def validate_batch!(batch)
      return if batch.nil?
      return if batch.is_a?(String) &&
        batch.bytesize.positive? &&
        batch.bytesize <= MAXIMUM_BATCH_BYTES &&
        batch.match?(/\A[a-zA-Z0-9_]+\z/)

      raise InvalidComponentToken, "invalid actor component batch"
    end
    private_class_method :validate_batch!

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

    # @rbs (Hash[untyped, untyped]) -> void
    def validate_locals!(locals)
      valid = locals.length <= MAXIMUM_LOCALS &&
        locals.keys.all? do |name|
          name.is_a?(String) &&
            name.match?(/\A[a-z_][a-zA-Z0-9_]*\z/) &&
            !RESERVED_LOCALS.include?(name) &&
            !RUBY_KEYWORDS.include?(name)
        end
      return if valid

      raise InvalidComponentToken, "invalid actor component locals"
    end
    private_class_method :validate_locals!

    # @rbs (String) -> void
    def validate_refresh_method!(refresh_method)
      return if REFRESH_METHODS.include?(refresh_method)

      raise InvalidComponentToken, "invalid actor component refresh method"
    end
    private_class_method :validate_refresh_method!

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
