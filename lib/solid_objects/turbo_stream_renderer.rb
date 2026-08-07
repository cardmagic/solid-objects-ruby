# rbs_inline: enabled

require "erb"
require "base64"

module SolidObjects
  module TurboStreamRenderer
    INVALIDATION_MARKER = "solid_objects_invalidation:"
    INVALIDATION_PATTERN = /<!--solid_objects_invalidation:([A-Za-z0-9_=-]+)-->/

    module_function

    # @rbs (Broadcast) -> String
    def observable(broadcast)
      reference = Reference.new(
        actor_type: broadcast.instance.actor_type,
        actor_id: broadcast.instance.actor_id
      )
      stream = observable_value(
        reference,
        broadcast.observable_name,
        broadcast.value
      )
      metadata = Base64.urlsafe_encode64(
        JSON.generate(
          "instance_id" => broadcast.instance_id,
          "revision" => broadcast.message.sequence,
          "observable_name" => broadcast.observable_name
        )
      )
      "#{stream}<!--#{INVALIDATION_MARKER}#{metadata}-->"
    end

    # @rbs (Reference, Symbol | String, untyped) -> String
    def observable_value(reference, name, value)
      target = DomIdentity.observable(reference, name)
      content = ERB::Util.html_escape(display_value(value))
      %(<turbo-stream action="replace" target="#{target}"><template><span id="#{target}">#{content}</span></template></turbo-stream>)
    end

    # @rbs (ComponentRegistration, Integer, Integer) -> String
    def component_refresh(registration, instance_id, revision)
      return morph_component_refresh(registration, instance_id, revision) if registration.morph?

      target = registration.dom_id
      source = ERB::Util.html_escape(
        registration.refresh_url(instance_id, revision)
      )
      revision_value = "#{instance_id}:#{revision}"
      %(<turbo-stream action="replace" target="#{target}"><template><turbo-frame id="#{target}" src="#{source}" data-solid-objects-revision="#{revision_value}" data-solid-objects-refresh="replace"></turbo-frame></template></turbo-stream>)
    end

    # @rbs (String) -> Hash[String, untyped]?
    def invalidation(stream)
      encoded = stream[INVALIDATION_PATTERN, 1]
      return unless encoded

      payload = JSON.parse(Base64.urlsafe_decode64(encoded))
      return unless payload["instance_id"].is_a?(Integer)
      return unless payload["revision"].is_a?(Integer)
      return unless payload["observable_name"].is_a?(String)

      payload
    rescue ArgumentError, JSON::ParserError
      nil
    end

    # @rbs (untyped) -> String
    def display_value(value)
      return value if value.is_a?(String)
      return value.to_s if value.is_a?(Numeric) || value == true || value == false
      return "" if value.nil?

      JSON.generate(value)
    end
    private_class_method :display_value

    # @rbs (ComponentRegistration, Integer, Integer) -> String
    def morph_component_refresh(registration, instance_id, revision)
      source = ERB::Util.html_escape(
        registration.refresh_url(instance_id, revision)
      )
      scope = DomIdentity.scope(registration.reference)
      %(<turbo-stream action="append" target="#{scope}"><template><solid-objects-refresh data-target="#{registration.dom_id}" data-source="#{source}" data-refresh-method="morph"></solid-objects-refresh></template></turbo-stream>)
    end
    private_class_method :morph_component_refresh
  end
end
