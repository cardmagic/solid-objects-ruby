# rbs_inline: enabled

require "action_cable/engine"

module SolidObjects
  class ActionCableBroadcastAdapter
    # @rbs (Broadcast) -> void
    def call(broadcast)
      reference = Reference.new(
        actor_type: broadcast.instance.actor_type,
        actor_id: broadcast.instance.actor_id
      )
      ActionCable.server.broadcast(
        StreamName.for(reference),
        TurboStreamRenderer.observable(broadcast)
      )
    end
  end
end
