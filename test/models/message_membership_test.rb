# frozen_string_literal: true

require "database_test_helper"

class MessageMembershipTest < ActiveSupport::TestCase
  test "derives ready and claimed state from table membership" do
    message = create_message
    ready_message = SolidObjects::ReadyMessage.create!(
      message:,
      instance: message.instance,
      sequence: message.sequence,
      available_at: Time.current
    )

    assert message.reload.ready?
    assert_not message.claimed?
    assert_not message.completed?

    SolidObjects::Record.transaction do
      ready_message.destroy!
      SolidObjects::ClaimedMessage.create!(
        message:,
        instance: message.instance,
        process_id: create_process.id,
        activation_token: SecureRandom.uuid,
        activation_generation: 3,
        claimed_at: Time.current
      )
    end

    assert_not message.reload.ready?
    assert message.claimed?
  end

  test "completion is durable after claimed membership is removed" do
    message = create_message
    claimed_message = SolidObjects::ClaimedMessage.create!(
      message:,
      instance: message.instance,
      process_id: create_process.id,
      activation_token: SecureRandom.uuid,
      activation_generation: 1,
      claimed_at: Time.current
    )

    SolidObjects::Record.transaction do
      message.update!(completed_at: Time.current, result: { "count" => 2 })
      claimed_message.destroy!
    end

    assert message.reload.completed?
    assert_not message.ready?
    assert_not message.claimed?
    assert_equal({ "count" => 2 }, message.result)
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

  def create_message
    instance = SolidObjects::Instance.create!(actor_type: "cart", actor_id: SecureRandom.uuid)
    SolidObjects::Message.create!(
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      message_name: "add",
      message_kind: "async",
      arguments: {},
      sequence: 1,
      request_id: SecureRandom.uuid,
      max_attempts: 5,
      enqueued_at: Time.current
    )
  end
end
