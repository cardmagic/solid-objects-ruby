# rbs_inline: enabled

class AddSolidObjectsCompletedIdempotencyKeys < ActiveRecord::Migration[7.1]
  # @rbs () -> void
  def change
    add_column SolidObjects.table_name(:instances),
      :completed_idempotency_keys,
      connection.adapter_name.match?(/postgres/i) ? :jsonb : :json
  end
end
