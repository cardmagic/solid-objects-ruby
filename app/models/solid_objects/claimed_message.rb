# rbs_inline: enabled

module SolidObjects
  class ClaimedMessage < Record
    self.table_name = SolidObjects.table_name(:claimed_messages)

    belongs_to :message, class_name: "SolidObjects::Message", inverse_of: :claimed_message
    belongs_to :instance, class_name: "SolidObjects::Instance", inverse_of: :claimed_messages
    belongs_to :process_record,
      class_name: "SolidObjects::Process",
      foreign_key: :process_id,
      optional: true
  end
end
