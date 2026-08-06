# rbs_inline: enabled

require "action_cable/channel/base"

module SolidObjects
  class ActorChannel < ActionCable::Channel::Base
    # @rbs () -> void
    def subscribed
      identity = StreamToken.verify(params.fetch("token"))
      actor_type = identity.fetch("actor_type")
      actor_id = identity.fetch("actor_id")
      SolidObjects.registry.fetch(actor_type)
      authorized = SolidObjects.configuration.authorize_subscription.call(
        actor_type:,
        actor_id:,
        authorization_context: connection
      )
      return reject unless authorized

      reference = Reference.new(actor_type:, actor_id:)
      stream_from StreamName.for(reference)
      ActorSnapshot.new(reference).observable_values.each do |name, value|
        transmit TurboStreamRenderer.observable_value(reference, name, value)
      end
    rescue KeyError, InvalidStreamToken, UnknownActorType
      reject
    end
  end
end
