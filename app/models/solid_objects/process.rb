# rbs_inline: enabled

module SolidObjects
  class Process < Record
    self.table_name = SolidObjects.table_name(:processes)

    has_many :instances,
      class_name: "SolidObjects::Instance",
      foreign_key: :activation_owner_id,
      inverse_of: :activation_owner,
      dependent: :nullify
  end
end
