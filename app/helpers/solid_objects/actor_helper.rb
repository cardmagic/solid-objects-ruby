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
      subscription = tag.turbo_cable_stream_source(
        channel: "SolidObjects::ActorChannel",
        token: StreamToken.generate(reference)
      )
      content = capture(actor, &block)

      content_tag(
        :div,
        safe_join([ subscription, content ]),
        id: DomIdentity.scope(reference)
      )
    end
  end
end
