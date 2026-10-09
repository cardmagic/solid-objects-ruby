# rbs_inline: enabled

class ApplyEntryUnorderedJob < ApplicationJob
  def perform(account_id:, kind:, amount_cents:)
    Account.find(account_id).apply_entry!(kind:, amount_cents:)
  end
end
