# frozen_string_literal: true

require "database_test_helper"

class FencingTest < ActiveSupport::TestCase
  setup do
    @instance = SolidObjects::Instance.create!(
      actor_type: "fence-test",
      actor_id: "one",
      state: { "value" => 0 }
    )
    @first_process = create_process
    @second_process = create_process
  end

  test "rejects a stale state write after a newer lease is acquired" do
    first_lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @first_process.id
    )
    @instance.update_column(:activation_expires_at, 1.second.ago)
    second_lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @second_process.id
    )

    second_lease.fenced_transaction do |instance|
      instance.update!(state: { "value" => 2 })
    end

    assert_raises(SolidObjects::LostActivation) do
      first_lease.fenced_transaction do |instance|
        instance.update!(state: { "value" => 1 })
      end
    end

    assert_equal({ "value" => 2 }, @instance.reload.state)
  end

  test "rejects a write after the current lease expires" do
    lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @first_process.id
    )
    @instance.update_column(:activation_expires_at, 1.second.ago)

    assert_raises(SolidObjects::LostActivation) do
      lease.fenced_transaction do |instance|
        instance.update!(state: { "value" => 1 })
      end
    end

    assert_equal({ "value" => 0 }, @instance.reload.state)
  end

  private

  def create_process
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )
  end
end
