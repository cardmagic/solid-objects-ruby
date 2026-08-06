# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class LeaseTest < ActiveSupport::TestCase
  class SlowActor < SolidObjects::Actor
    actor_type "lease-renewal"

    class << self
      attr_accessor :started, :release
    end

    def run
      self.class.started << true
      self.class.release.pop
    end
  end

  setup do
    @instance = SolidObjects::Instance.create!(actor_type: "lease-test", actor_id: "one")
    @first_process = create_process
    @second_process = create_process
  end

  test "acquires a lease with the first fencing generation" do
    lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @first_process.id
    )

    assert_equal @first_process.id, lease.owner_id
    assert_equal 1, lease.generation
    assert_operator lease.expires_at, :>, Time.current

    @instance.reload
    assert_equal lease.owner_id, @instance.activation_owner_id
    assert_equal lease.generation, @instance.activation_generation
  end

  test "does not acquire an actor with an unexpired lease" do
    SolidObjects::Lease.acquire(instance_id: @instance.id, owner_id: @first_process.id)

    lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @second_process.id
    )

    assert_nil lease
  end

  test "increments the fencing generation after expiration" do
    first_lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @first_process.id
    )
    @instance.update_column(:activation_expires_at, 1.second.ago)

    second_lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @second_process.id
    )

    assert_equal first_lease.generation + 1, second_lease.generation
    assert_equal @second_process.id, second_lease.owner_id
  end

  test "renews only the matching live generation" do
    lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @first_process.id
    )
    original_expiration = lease.expires_at

    renewed_lease = lease.renew

    assert_equal lease.generation, renewed_lease.generation
    assert_operator renewed_lease.expires_at, :>=, original_expiration
  end

  test "releases only the matching generation" do
    lease = SolidObjects::Lease.acquire(
      instance_id: @instance.id,
      owner_id: @first_process.id
    )

    assert lease.release
    assert_nil @instance.reload.activation_owner_id
    assert_equal lease.generation, @instance.activation_generation
  end

  test "renews the activation while a handler is still running" do
    SlowActor.started = Queue.new
    SlowActor.release = Queue.new
    SolidObjects.configuration.lease_duration = 0.5
    SolidObjects.configuration.lease_renewal_interval = 0.05
    renewed = Queue.new
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.activation.renewed") do
      renewed << true
    end
    message_reference = SlowActor.ref("slow").run
    worker = SolidObjects::Worker.new

    thread = Thread.new { worker.run_once }
    Timeout.timeout(2) { SlowActor.started.pop }
    Timeout.timeout(2) { renewed.pop }
    SlowActor.release << true
    thread.join

    assert_equal "completed", message_reference.status
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    SlowActor.release << true if thread&.alive?
    thread&.join
    worker&.stop
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
