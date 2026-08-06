# rbs_inline: enabled

module SolidObjects
  class Broadcast < Record
    self.table_name = SolidObjects.table_name(:broadcasts)

    belongs_to :message, class_name: "SolidObjects::Message"
    belongs_to :instance, class_name: "SolidObjects::Instance"
  end
end
