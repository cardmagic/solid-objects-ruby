# frozen_string_literal: true

require "database_test_helper"

class ProcessLifecycleTest < ActiveSupport::TestCase
  class RecoveryActor < SolidObjects::Actor
    actor_type "process-recovery"

    attribute :runs, default: 0

    message :run do
      state.runs += 1
    end
  end

  test "recovers a claimed message after its worker heartbeat expires" do
    message_reference = RecoveryActor.ref("one").tell(:run)
    message = SolidObjects::Message.find(message_reference.id)
    instance = message.instance
    dead_process = create_process(last_heartbeat_at: 2.minutes.ago)
    lease = SolidObjects::Lease.acquire(
      instance_id: instance.id,
      owner_id: dead_process.id
    )
    ready_message = SolidObjects::ReadyMessage.find_by!(message:)
    ready_message.destroy!
    message.update!(attempt_count: 1, started_at: Time.current)
    SolidObjects::ClaimedMessage.create!(
      message:,
      instance:,
      process_id: dead_process.id,
      activation_generation: lease.generation,
      claimed_at: Time.current
    )

    assert_equal 1, SolidObjects::ProcessRegistry.cleanup_dead
    assert_nil instance.reload.activation_owner_id

    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal({ "runs" => 1 }, instance.reload.state)
    assert_equal 2, message.reload.attempt_count
    assert message.completed?
  ensure
    worker&.stop
  end

  test "stop releases cached activations and records graceful shutdown" do
    RecoveryActor.ref("one").tell(:run)
    worker = SolidObjects::Worker.new

    worker.run_until_idle
    instance = SolidObjects::Instance.find_by!(actor_type: "process-recovery")
    process_record = instance.activation_owner
    assert process_record

    worker.stop

    assert_nil instance.reload.activation_owner_id
    assert_equal "stopped", process_record.reload.shutdown_state
    assert process_record.shutdown_requested_at
    assert process_record.stopped_at
  end

  test "process deregistration releases owned coordination records" do
    process_registry = SolidObjects::ProcessRegistry.new
    process_record = process_registry.register
    instance = SolidObjects::Instance.create!(
      actor_type: "process-recovery",
      actor_id: "owned"
    )
    SolidObjects::Lease.acquire(
      instance_id: instance.id,
      owner_id: process_record.id
    )

    process_registry.stop

    assert_nil instance.reload.activation_owner_id
    assert_equal "stopped", process_record.reload.shutdown_state
  end

  private

  def create_process(last_heartbeat_at:)
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: 2.minutes.ago,
      last_heartbeat_at:,
      metadata: {}
    )
  end
end
