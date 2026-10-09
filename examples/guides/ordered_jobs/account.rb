# rbs_inline: enabled

class Account < ApplicationRecord
  class InsufficientFunds < StandardError; end
  class OutOfSequence < StandardError; end

  def apply_entry!(kind:, amount_cents:)
    change = (kind == "deposit") ? amount_cents : -amount_cents
    raise InsufficientFunds, "balance #{balance_cents}, change #{change}" if balance_cents + change < 0

    update!(balance_cents: balance_cents + change)
  end

  def apply_entry_in_sequence!(sequence:, kind:, amount_cents:)
    with_lock do
      raise OutOfSequence, "expected #{next_sequence}, received #{sequence}" if sequence > next_sequence
      next if sequence < next_sequence

      apply_entry!(kind:, amount_cents:)
      update!(next_sequence: next_sequence + 1)
    end
  end
end
