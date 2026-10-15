# frozen_string_literal: true

require_relative "../guides/guide_test_helper"
require_relative "../../examples/compare/customer_billing_sync/customer_billing_sync"

module BillingApi
  class LostResponse < StandardError; end
  class Unavailable < StandardError; end

  class << self
    attr_accessor :calls, :pushed, :lose_next_response, :unavailable

    def reset
      self.calls = []
      self.pushed = {}
      self.lose_next_response = false
      self.unavailable = false
    end

    def push_subscription(idempotency_key:, customer_id:, version:, plan:)
      calls << { "key" => idempotency_key, "customer_id" => customer_id, "version" => version }
      raise Unavailable, "the billing API is down" if unavailable

      pushed[idempotency_key] ||= { "customer_id" => customer_id, "version" => version, "plan" => plan }
      if lose_next_response
        self.lose_next_response = false
        raise LostResponse, "the worker stopped before it recorded the result"
      end

      { "billing_version" => version }
    end
  end
end

class CustomerBillingSyncTest < ActiveSupport::TestCase
  include SolidObjects::TestHelper
  include GuideTestSupport

  setup do
    BillingApi.reset
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
    load File.expand_path("../../examples/compare/customer_billing_sync/solid_objects.rb", __dir__)
    CustomerBillingSync.ensure_registered!
  end

  teardown do
    SolidObjects.configuration.max_attempts = 5
  end

  def pending_effect_count
    SolidObjects::Effect.where(status: [ "pending", "processing" ]).count
  end

  def drain_until_idle
    10.times { drain_solid_objects(roles: [ :effects, :actors ]) }
  end

  test "one customer's updates reach the billing API one at a time and in order" do
    customer = CustomerBillingSync.ref("customer-1")
    [ [ 1, "basic" ], [ 2, "pro" ], [ 3, "team" ] ].each do |version, plan|
      customer.async(idempotency_key: "customer-1-v#{version}").update_subscription(version:, plan:)
    end

    drain_solid_objects(roles: [ :actors ])
    assert_equal 1, pending_effect_count

    drain_until_idle

    assert_equal [ 1, 2, 3 ], BillingApi.calls.map { |call| call.fetch("version") }
    assert_equal 3, customer.snapshot.last_synced_version
    assert_empty customer.snapshot.pending
  end

  test "different customers push at the same time" do
    CustomerBillingSync.ref("customer-1").update_subscription(version: 1, plan: "basic")
    CustomerBillingSync.ref("customer-2").update_subscription(version: 1, plan: "pro")

    assert_equal 2, pending_effect_count
  end

  test "a push that runs again after a lost response uses the same idempotency key" do
    customer = CustomerBillingSync.ref("customer-1")
    BillingApi.lose_next_response = true

    customer.update_subscription(version: 1, plan: "basic")
    drain_until_idle

    assert_equal 2, BillingApi.calls.length
    assert_equal 1, BillingApi.calls.map { |call| call.fetch("key") }.uniq.length
    assert_equal 1, BillingApi.pushed.length
    assert_equal 1, customer.snapshot.last_synced_version
  end

  test "a repeated or older update changes nothing" do
    customer = CustomerBillingSync.ref("customer-1")
    customer.update_subscription(version: 2, plan: "pro")
    drain_until_idle

    customer.update_subscription(version: 2, plan: "pro")
    customer.update_subscription(version: 1, plan: "basic")
    drain_until_idle

    assert_equal [ 2 ], BillingApi.calls.map { |call| call.fetch("version") }
  end

  test "a newer update during the backoff waits for the retry" do
    SolidObjects.configuration.max_attempts = 1
    customer = CustomerBillingSync.ref("customer-1")
    BillingApi.unavailable = true
    customer.update_subscription(version: 1, plan: "basic")
    drain_until_idle
    calls_after_failure = BillingApi.calls.length

    customer.update_subscription(version: 2, plan: "pro")
    drain_until_idle

    assert_equal calls_after_failure, BillingApi.calls.length
    assert_equal [ 1, 2 ], customer.snapshot.pending.map { |update| update.fetch("version") }
  end

  test "a failed push waits with backoff and runs again after a restart" do
    SolidObjects.configuration.max_attempts = 1
    customer = CustomerBillingSync.ref("customer-1")
    BillingApi.unavailable = true

    customer.update_subscription(version: 1, plan: "basic")
    drain_until_idle

    snapshot = customer.snapshot
    assert_equal 1, snapshot.retry_count
    assert_equal 0, snapshot.last_synced_version
    assert_in_delta 2.minutes.from_now.to_i, Time.iso8601(snapshot.next_retry_at).to_i, 5

    SolidObjects.reset_caller_process!
    BillingApi.unavailable = false
    run_due_reminders(now: 3.minutes.from_now)
    drain_until_idle

    snapshot = customer.snapshot
    assert_equal 1, snapshot.last_synced_version
    assert_equal 0, snapshot.retry_count
    assert_nil snapshot.next_retry_at
  end
end
