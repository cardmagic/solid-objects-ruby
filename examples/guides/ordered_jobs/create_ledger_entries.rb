# rbs_inline: enabled

class CreateLedgerEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :ledger_entries do |table|
      table.string :account_id, null: false
      table.string :entry_id, null: false
      table.string :kind, null: false
      table.integer :amount_cents, null: false
      table.timestamps
    end
    add_index :ledger_entries, [ :account_id, :entry_id ], unique: true
  end
end
