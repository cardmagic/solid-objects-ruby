# rbs_inline: enabled

class LedgerAccount < SolidObjects::Actor
  RECENT_ENTRY_LIMIT = 100

  attribute :balance_cents, default: 0
  attribute :recent_entry_ids, default: -> { [] }
  attribute :statement_balance_cents, default: nil

  def apply(entry_id:, kind:, amount_cents:)
    return balance_cents if recent_entry_ids.include?(entry_id)

    change = (kind == "deposit") ? amount_cents : -amount_cents
    reject(:insufficient_funds, "The balance is too low for this withdrawal") if balance_cents + change < 0

    self.balance_cents += change
    self.recent_entry_ids = (recent_entry_ids + [ entry_id ]).last(RECENT_ENTRY_LIMIT)
    schedule(at: 1.day.from_now, key: "daily").close_statement
    balance_cents
  end

  def close_statement
    self.statement_balance_cents = balance_cents
  end
end
