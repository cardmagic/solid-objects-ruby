# rbs_inline: enabled

module SolidObjects
  class Broadcast < Record
    self.table_name = SolidObjects.table_name(:broadcasts)

    belongs_to :message, class_name: "SolidObjects::Message"
    belongs_to :instance, class_name: "SolidObjects::Instance"

    # @rbs () -> bool
    def broadcasts_value?
      return false if observable_name == PayloadBroadcast::REVISION_OBSERVABLE

      actor_class = SolidObjects.registry.fetch(instance.actor_type)
      actor_class.definition.broadcasts_observable_value?(observable_name)
    end
  end
end
