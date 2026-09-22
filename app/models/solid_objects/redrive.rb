# rbs_inline: enabled

module SolidObjects
  class Redrive < Record
    self.table_name = SolidObjects.table_name(:redrives)
  end
end
