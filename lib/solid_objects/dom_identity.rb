# rbs_inline: enabled

require "digest"

module SolidObjects
  module DomIdentity
    module_function

    # @rbs (Reference) -> String
    def scope(reference)
      "solid_objects_actor_#{identity_digest(reference)}"
    end

    # @rbs (Reference, Symbol | String) -> String
    def observable(reference, name)
      "#{scope(reference)}_observable_#{normalized_name(name)}"
    end

    # @rbs (Reference, Symbol | String, ?key: String | Integer?) -> String
    def component(reference, name, key: nil)
      identity = "#{scope(reference)}_component_#{normalized_name(name)}"
      return identity unless key

      "#{identity}_#{component_key_digest(key)}"
    end

    # @rbs (Reference) -> String
    def identity_digest(reference)
      Digest::SHA256.hexdigest(
        "#{reference.actor_type}\0#{reference.actor_id}"
      ).first(24)
    end
    private_class_method :identity_digest

    # @rbs (Symbol | String) -> String
    def normalized_name(name)
      name.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
    end
    private_class_method :normalized_name

    # @rbs (String | Integer) -> String
    def component_key_digest(key)
      Digest::SHA256.hexdigest(JSON.generate(key)).first(24)
    end
    private_class_method :component_key_digest
  end
end
