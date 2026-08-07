# rbs_inline: enabled

require "active_support/message_verifier"

module SolidObjects
  module StreamToken
    PURPOSE = "solid_objects.actor_stream"
    MAXIMUM_OBSERVABLES = 100

    module_function

    # @rbs (Reference, ?observables: Array[String]?) -> String
    def generate(reference, observables: nil)
      identity = {
        "actor_type" => reference.actor_type,
        "actor_id" => reference.actor_id
      }
      identity["observables"] = observables if observables
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

      observables = identity["observables"]
      return identity unless observables

      valid = observables.is_a?(Array) &&
        observables.length <= MAXIMUM_OBSERVABLES &&
        observables.uniq.length == observables.length &&
        observables.all? do |observable|
          observable.is_a?(String) &&
            observable.match?(/\A[a-zA-Z0-9_]+\z/)
        end
      return identity if valid

      raise InvalidStreamToken, "invalid actor stream observables"
    end
    private_class_method :validate_identity!

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
