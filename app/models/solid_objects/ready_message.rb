# rbs_inline: enabled

module SolidObjects
  class ReadyMessage < Record
    self.table_name = SolidObjects.table_name(:ready_messages)

    belongs_to :message, class_name: "SolidObjects::Message", inverse_of: :ready_message
    belongs_to :instance, class_name: "SolidObjects::Instance", inverse_of: :ready_messages
  end
end
