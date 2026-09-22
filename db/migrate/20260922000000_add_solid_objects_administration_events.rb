# rbs_inline: enabled

class AddSolidObjectsAdministrationEvents < ActiveRecord::Migration[7.1]
  # @rbs () -> void
  def change
    create_table SolidObjects.table_name(:administration_events) do |definition|
      definition.string :action, null: false, limit: 64
      definition.string :kind, null: false, limit: 32
      definition.string :subject_id, limit: 191
      json_column definition, :filters
      definition.string :actor, limit: 255
      definition.datetime :occurred_at, null: false, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index [ :occurred_at, :id ], name: "idx_so_admin_events_occurred"
      definition.index [ :kind, :subject_id ], name: "idx_so_admin_events_subject"
    end
  end

  private

  # @rbs () -> Symbol
  def json_column_type
    connection.adapter_name.match?(/postgres/i) ? :jsonb : :json
  end

  # @rbs (untyped, Symbol, ?null: bool) -> void
  def json_column(definition, name, null: true)
    definition.public_send(json_column_type, name, null:)
  end
end
