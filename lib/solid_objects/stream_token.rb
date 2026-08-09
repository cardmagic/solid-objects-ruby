# rbs_inline: enabled

require "active_support/message_verifier"

module SolidObjects
  module StreamToken
    PURPOSE = "solid_objects.actor_stream"
    MAXIMUM_OBSERVABLES = 100

    module_function

    # @rbs (Reference, ?observables: Array[String]?, ?payloads: Array[String]?) -> String
    def generate(reference, observables: nil, payloads: nil)
      identity = {
        "actor_type" => reference.actor_type,
        "actor_id" => reference.actor_id
      }
      identity["observables"] = observables if observables
      identity["payloads"] = payloads if payloads
      validate_identity!(identity)
      verifier.generate(identity, purpose: PURPOSE)
    end

    # @rbs (String) -> Hash[String, untyped]
    def verify(token)
      identity = verifier.verified(token, purpose: PURPOSE)
      validate_identity!(identity)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise InvalidStreamToken, "invalid actor stream token"
    end

    # @rbs (Hash[String, untyped]) -> Hash[String, untyped]
    def validate_identity!(identity)
      unless identity.is_a?(Hash) &&
          identity["actor_type"].is_a?(String) &&
          identity["actor_id"].is_a?(String)
        raise InvalidStreamToken, "invalid actor stream token"
      end

      validate_names!(identity["observables"], "observables")
      validate_names!(identity["payloads"], "payloads")
      identity
    end

    # @rbs (untyped, String) -> void
    def validate_names!(names, label)
      return unless names

      valid = names.is_a?(Array) &&
        names.length <= MAXIMUM_OBSERVABLES &&
        names.uniq.length == names.length &&
        names.all? do |name|
          name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_]+\z/)
        end
      return if valid

      raise InvalidStreamToken, "invalid actor stream #{label}"
    end
    private_class_method :validate_identity!
    private_class_method :validate_names!

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
