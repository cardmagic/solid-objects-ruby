# rbs_inline: enabled

module SolidObjects
  class AdministrationEvent < Record
    self.table_name = SolidObjects.table_name(:administration_events)
  end
end
