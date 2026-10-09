# rbs_inline: enabled

class LedgerAccount < SolidObjects::Actor
  attribute :balance_cents, default: 0
  attribute :statement_balance_cents, default: nil

  def apply(entry_id:, kind:, amount_cents:)
    return balance_cents if LedgerEntry.exists?(account_id: actor_id, entry_id:)

    change = (kind == "deposit") ? amount_cents : -amount_cents
    reject(:insufficient_funds, "The balance is too low for this withdrawal") if balance_cents + change < 0

    self.balance_cents += change
    commit_action(:record_ledger_entry, account_id: actor_id, entry_id:, kind:, amount_cents:)
    schedule(at: 1.day.from_now, key: "daily").close_statement
    balance_cents
  end

  def close_statement
    self.statement_balance_cents = balance_cents
  end
end
