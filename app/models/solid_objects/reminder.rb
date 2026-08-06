# rbs_inline: enabled

module SolidObjects
  class Reminder < Record
    self.table_name = SolidObjects.table_name(:reminders)

    belongs_to :instance, class_name: "SolidObjects::Instance"
  end
end
