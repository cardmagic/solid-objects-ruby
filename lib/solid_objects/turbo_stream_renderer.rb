# rbs_inline: enabled

require "erb"

module SolidObjects
  module TurboStreamRenderer
    module_function

    # @rbs (Broadcast) -> String
    def observable(broadcast)
      reference = Reference.new(
        actor_type: broadcast.instance.actor_type,
        actor_id: broadcast.instance.actor_id
      )
      observable_value(reference, broadcast.observable_name, broadcast.value)
    end

    # @rbs (Reference, Symbol | String, untyped) -> String
    def observable_value(reference, name, value)
      target = DomIdentity.observable(reference, name)
      content = ERB::Util.html_escape(display_value(value))
      %(<turbo-stream action="replace" target="#{target}"><template><span id="#{target}">#{content}</span></template></turbo-stream>)
    end

    # @rbs (untyped) -> String
    def display_value(value)
      return value if value.is_a?(String)
      return value.to_s if value.is_a?(Numeric) || value == true || value == false
      return "" if value.nil?

      JSON.generate(value)
    end
    private_class_method :display_value
  end
end
