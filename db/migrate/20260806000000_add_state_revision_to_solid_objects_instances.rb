# rbs_inline: enabled

class AddStateRevisionToSolidObjectsInstances < ActiveRecord::Migration[8.0]
  # @rbs () -> void
  def change
    add_column SolidObjects.table_name(:instances),
      :state_revision,
      :bigint,
      null: false,
      default: 0
  end
end
