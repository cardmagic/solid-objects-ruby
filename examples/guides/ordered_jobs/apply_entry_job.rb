# rbs_inline: enabled

class ApplyEntryJob < ApplicationJob
  retry_on Account::OutOfSequence, wait: 5.seconds, attempts: 20

  def perform(account_id:, sequence:, kind:, amount_cents:)
    Account.find(account_id).apply_entry_in_sequence!(sequence:, kind:, amount_cents:)
  end
end
