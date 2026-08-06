# rbs_inline: enabled

require "digest"

module SolidObjects
  module StreamName
    module_function

    # @rbs (Reference | Hash[String, String]) -> String
    def for(reference)
      identity = identity_for(reference)
      digest = Digest::SHA256.hexdigest(
        "#{identity.fetch("actor_type")}\0#{identity.fetch("actor_id")}"
      ).first(32)
      "solid_objects_stream_#{digest}"
    end

    # @rbs (Reference | Hash[String, String]) -> Hash[String, String]
    def identity_for(reference)
      return reference if reference.is_a?(Hash)

      {
        "actor_type" => reference.actor_type,
        "actor_id" => reference.actor_id
      }
    end
    private_class_method :identity_for
  end
end
