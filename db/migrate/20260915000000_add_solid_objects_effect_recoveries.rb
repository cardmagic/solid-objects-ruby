# rbs_inline: enabled

class AddSolidObjectsEffectRecoveries < ActiveRecord::Migration[7.1]
  # @rbs () -> void
  def change
    create_table SolidObjects.table_name(:effect_recoveries), id: :string, limit: 36, primary_key: :effect_id do |definition|
      definition.references :instance, null: false,
        foreign_key: { to_table: SolidObjects.table_name(:instances), on_delete: :cascade, name: "fk_so_effect_recoveries_instance" }
      definition.string :recovery_operation, limit: 191
      definition.string :status_operation, limit: 191
      definition.float :recovery_timeout
      definition.datetime :retired_at, precision: 6
      definition.timestamps precision: 6, null: false
      definition.check_constraint "recovery_timeout IS NULL OR recovery_timeout > 0", name: "chk_so_effect_recoveries_timeout"
    end
  end
end
