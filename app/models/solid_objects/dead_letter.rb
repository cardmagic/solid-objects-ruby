# rbs_inline: enabled

module SolidObjects
  class DeadLetter < Record
    self.table_name = SolidObjects.table_name(:dead_letters)

    belongs_to :message, class_name: "SolidObjects::Message", inverse_of: :dead_letter
    belongs_to :instance, class_name: "SolidObjects::Instance"
    belongs_to :retried_message,
      class_name: "SolidObjects::Message",
      optional: true
  end
end
