# rbs_inline: enabled

class RenameMessageDispatchColumns < ActiveRecord::Migration[8.0]
  # @rbs () -> void
  def up
    remove_check_constraint messages_table, name: "chk_so_messages_kind"
    rename_column messages_table, :message_name, :operation
    rename_column messages_table, :message_kind, :delivery_mode
    rename_column reminders_table, :message_name, :operation
    rename_column effects_table, :success_message_name, :success_operation
    rename_column effects_table, :failure_message_name, :failure_operation
    rename_column dead_letters_table, :message_name, :operation
    add_check_constraint messages_table,
      "delivery_mode IN ('async', 'sync', 'internal')",
      name: "chk_so_messages_delivery_mode"
  end

  # @rbs () -> void
  def down
    remove_check_constraint messages_table, name: "chk_so_messages_delivery_mode"
    rename_column messages_table, :operation, :message_name
    rename_column messages_table, :delivery_mode, :message_kind
    rename_column reminders_table, :operation, :message_name
    rename_column effects_table, :success_operation, :success_message_name
    rename_column effects_table, :failure_operation, :failure_message_name
    rename_column dead_letters_table, :operation, :message_name
    add_check_constraint messages_table,
      "message_kind IN ('async', 'sync', 'internal')",
      name: "chk_so_messages_kind"
  end

  private

  # @rbs () -> String
  def messages_table
    SolidObjects.table_name(:messages)
  end

  # @rbs () -> String
  def reminders_table
    SolidObjects.table_name(:reminders)
  end

  # @rbs () -> String
  def effects_table
    SolidObjects.table_name(:effects)
  end

  # @rbs () -> String
  def dead_letters_table
    SolidObjects.table_name(:dead_letters)
  end
end
