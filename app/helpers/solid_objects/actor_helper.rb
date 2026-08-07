# rbs_inline: enabled

module SolidObjects
  module ActorHelper
    # @rbs (Reference, ?authorization_context: untyped) { (ActorView) -> untyped } -> untyped
    def solid_object(reference, authorization_context: self, &block)
      actor = ActorView.new(
        reference:,
        view_context: self,
        authorization_context:
      )
      content = capture(actor, &block)
      subscription_data = {
        token: StreamToken.generate(
          reference,
          observables: actor.scalar_observable_names
        )
      }
      if actor.component_tokens.any?
        subscription_data[:components] = JSON.generate(actor.component_tokens)
      end
      subscription = tag.turbo_cable_stream_source(
        channel: "SolidObjects::ActorChannel",
        data: subscription_data
      )
      refresh_client = if actor.morph_components?
        javascript_include_tag(
          "solid_objects/component_refresh",
          type: "module",
          data: { turbo_track: "reload" }
        )
      end

      content_tag(
        :div,
        safe_join([ refresh_client, subscription, content ].compact),
        id: DomIdentity.scope(reference)
      )
    end
  end
end
