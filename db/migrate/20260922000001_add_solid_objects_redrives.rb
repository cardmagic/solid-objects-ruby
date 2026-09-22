# rbs_inline: enabled

class AddSolidObjectsRedrives < ActiveRecord::Migration[7.1]
  # @rbs () -> void
  def change
    create_table SolidObjects.table_name(:redrives), id: :string, limit: 64 do |definition|
      definition.string :kind, null: false, limit: 32
      definition.public_send(json_type, :filters, null: false)
      definition.string :status, null: false, default: "running", limit: 32
      definition.string :active_scope, limit: 191
      definition.integer :moved, null: false, default: 0
      definition.integer :move_limit
      definition.string :actor, limit: 255
      definition.datetime :started_at, null: false, precision: 6
      definition.datetime :finished_at, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index :active_scope, unique: true, name: "idx_so_redrives_active_scope"
      definition.index [ :status, :started_at, :id ], name: "idx_so_redrives_poll"
      definition.check_constraint "moved >= 0", name: "chk_so_redrives_moved"
      definition.check_constraint "move_limit IS NULL OR move_limit > 0", name: "chk_so_redrives_limit"
      definition.check_constraint "status IN ('running', 'completed', 'cancelled')", name: "chk_so_redrives_status"
    end
  end

  private

  # @rbs () -> Symbol
  def json_type
    connection.adapter_name.match?(/postgres/i) ? :jsonb : :json
  end
end
