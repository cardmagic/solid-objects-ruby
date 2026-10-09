# frozen_string_literal: true

require_relative "guide_test_helper"
require_relative "../../examples/guides/ordered_jobs/account"
require_relative "../../examples/guides/ordered_jobs/apply_entry_unordered_job"
require_relative "../../examples/guides/ordered_jobs/apply_entry_job"
require_relative "../../examples/guides/ordered_jobs/ledger_entry"
require_relative "../../examples/guides/ordered_jobs/ledger_account"

class OrderedJobsGuideTest < ActiveSupport::TestCase
  include SolidObjects::TestHelper
  include ActiveJob::TestHelper
  include GuideTestSupport

  setup do
    GuideSchema.reset
    load File.expand_path("../../examples/guides/ordered_jobs/solid_objects.rb", __dir__)
    LedgerAccount.ensure_registered!
  end

  def applied_entry_ids(account_id)
    LedgerEntry.where(account_id:).order(:id).pluck(:entry_id)
  end

  test "jobs that run in a different order than they were enqueued reject a valid withdrawal" do
    account = Account.create!(balance_cents: 0)

    assert_raises(Account::InsufficientFunds) do
      ApplyEntryUnorderedJob.perform_now(account_id: account.id, kind: "withdrawal", amount_cents: 80)
    end
    ApplyEntryUnorderedJob.perform_now(account_id: account.id, kind: "deposit", amount_cents: 100)

    assert_equal 100, account.reload.balance_cents
  end

  test "a sequence guard applies entries in order and ignores a repeated entry" do
    account = Account.create!(balance_cents: 0)

    assert_raises(Account::OutOfSequence) do
      account.apply_entry_in_sequence!(sequence: 2, kind: "withdrawal", amount_cents: 80)
    end
    account.apply_entry_in_sequence!(sequence: 1, kind: "deposit", amount_cents: 100)
    account.apply_entry_in_sequence!(sequence: 2, kind: "withdrawal", amount_cents: 80)
    account.apply_entry_in_sequence!(sequence: 1, kind: "deposit", amount_cents: 100)

    assert_equal 20, account.reload.balance_cents
    assert_equal 3, account.next_sequence
  end

  test "the sequenced job enqueues a retry when its entry arrives early" do
    account = Account.create!(balance_cents: 0)

    assert_enqueued_jobs 1, only: ApplyEntryJob do
      ApplyEntryJob.perform_now(account_id: account.id, sequence: 2, kind: "withdrawal", amount_cents: 80)
    end
    assert_equal 0, account.reload.balance_cents
  end

  test "each account applies its entries in enqueue order while two workers run" do
    entries = [
      [ "alice", "alice-1", "deposit", 100 ],
      [ "bob", "bob-1", "deposit", 50 ],
      [ "alice", "alice-2", "withdrawal", 80 ],
      [ "bob", "bob-2", "withdrawal", 50 ],
      [ "alice", "alice-3", "deposit", 5 ]
    ]
    entries.each do |account_id, entry_id, kind, amount_cents|
      LedgerAccount.ref(account_id).async(idempotency_key: entry_id).apply(entry_id:, kind:, amount_cents:)
    end

    workers = Array.new(2) { SolidObjects::Worker.new }
    concurrently(2, prepare: ->(index) { workers.fetch(index) }) { |worker| worker.run_until_idle }
    workers.each(&:stop)

    assert_equal [ "alice-1", "alice-2", "alice-3" ], applied_entry_ids("alice")
    assert_equal 25, LedgerAccount.ref("alice").snapshot.balance_cents
    assert_equal [ "bob-1", "bob-2" ], applied_entry_ids("bob")
    assert_equal 0, LedgerAccount.ref("bob").snapshot.balance_cents
  end

  test "a rejected entry does not block the entries after it" do
    account = LedgerAccount.ref("carol")
    account.async(idempotency_key: "carol-1").apply(entry_id: "carol-1", kind: "withdrawal", amount_cents: 10)
    account.async(idempotency_key: "carol-2").apply(entry_id: "carol-2", kind: "deposit", amount_cents: 30)

    drain_solid_objects(roles: [ :actors ])

    assert_equal "rejected", account.find_by(idempotency_key: "carol-1").outcome.status
    assert_equal 30, account.snapshot.balance_cents
  end

  test "a repeated enqueue and a repeated delivery apply an entry once" do
    account = LedgerAccount.ref("dave")
    2.times do
      account.async(idempotency_key: "dave-1").apply(entry_id: "dave-1", kind: "deposit", amount_cents: 40)
    end
    drain_solid_objects(roles: [ :actors ])

    account.apply(entry_id: "dave-1", kind: "deposit", amount_cents: 40)

    assert_equal 40, account.snapshot.balance_cents
    assert_equal [ "dave-1" ], applied_entry_ids("dave")
  end

  test "a repeated entry after more than one hundred newer entries still applies once" do
    account = LedgerAccount.ref("frank")
    102.times { |index| account.apply(entry_id: "frank-#{index}", kind: "deposit", amount_cents: 1) }

    account.apply(entry_id: "frank-0", kind: "deposit", amount_cents: 1)

    assert_equal 102, account.snapshot.balance_cents
  end

  test "the statement reminder runs after a restart" do
    account = LedgerAccount.ref("erin")
    account.apply(entry_id: "erin-1", kind: "deposit", amount_cents: 70)
    SolidObjects.reset_caller_process!

    run_due_reminders(now: 25.hours.from_now)
    drain_solid_objects(roles: [ :actors ])

    assert_equal 70, account.snapshot.statement_balance_cents
  end
end
