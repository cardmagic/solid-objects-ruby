# rbs_inline: enabled

module SolidObjects
  class EffectRecovery < Record
    self.table_name = SolidObjects.table_name(:effect_recoveries)
    self.primary_key = "effect_id"

    belongs_to :instance, class_name: "SolidObjects::Instance"
  end
end
