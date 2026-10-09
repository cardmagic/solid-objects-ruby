# rbs_inline: enabled

SolidObjects.register_commit_action(:record_ledger_entry) do |arguments, _context|
  LedgerEntry.create!(
    account_id: arguments.fetch("account_id"),
    entry_id: arguments.fetch("entry_id"),
    kind: arguments.fetch("kind"),
    amount_cents: arguments.fetch("amount_cents")
  )
end
