# rbs_inline: enabled

require "active_support/message_verifier"

module SolidObjects
  module StreamToken
    PURPOSE = "solid_objects.actor_stream"

    module_function

    # @rbs (Reference) -> String
    def generate(reference)
      verifier.generate(
        {
          "actor_type" => reference.actor_type,
          "actor_id" => reference.actor_id
        },
        purpose: PURPOSE
      )
    end

    # @rbs (String) -> Hash[String, String]
    def verify(token)
      identity = verifier.verified(token, purpose: PURPOSE)
      unless identity.is_a?(Hash) &&
          identity["actor_type"].is_a?(String) &&
          identity["actor_id"].is_a?(String)
        raise InvalidStreamToken, "invalid actor stream token"
      end

      identity
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise InvalidStreamToken, "invalid actor stream token"
    end

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
