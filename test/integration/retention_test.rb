# frozen_string_literal: true

require "database_test_helper"

class RetentionTest < ActiveSupport::TestCase
  class RetentionActor < SolidObjects::Actor
    actor_type "retention"

    attribute :value, default: 0

    def increment
      self.value += 1
    end

    def fail
      raise "failed"
    end
  end

  class ShortRetentionActor < SolidObjects::Actor
    actor_type "short-retention"

    def run
    end
  end

  class EffectActor < SolidObjects::Actor
    actor_type "retention-effect"

    def run
      emit :unfinished_retention_effect
    end
  end

  class ExpiringActor < SolidObjects::Actor
    actor_type "expiring-retention"

    attribute :value, default: 0

    def increment
      self.value += 1
    end

    def schedule_increment
      schedule :increment, at: 1.day.from_now, arguments: {}
    end
  end

  test "message pruning previews and deletes only terminal unreferenced history" do
    old_message = completed_message { RetentionActor.ref("old").increment }
    recent_message = completed_message { RetentionActor.ref("recent").increment }
    protected_message = completed_message { EffectActor.ref("effect").run }
    old_message.update!(completed_at: 31.days.ago)
    protected_message.update!(completed_at: 31.days.ago)
    SolidObjects.configuration.max_attempts = 1
    assert_raises(SolidObjects::MessageFailed) { RetentionActor.ref("dead").fail }

    pruner = SolidObjects::MessagePruner.new(now: Time.current)

    assert_equal 1, pruner.preview
    assert SolidObjects::Message.exists?(old_message.id)
    assert_equal 1, pruner.prune
    refute SolidObjects::Message.exists?(old_message.id)
    assert SolidObjects::Message.exists?(recent_message.id)
    assert SolidObjects::Message.exists?(protected_message.id)
    assert_equal 1, SolidObjects::DeadLetter.count
  end

  test "message pruning honors per actor retention" do
    default_message = completed_message { RetentionActor.ref("default").increment }
    short_message = completed_message { ShortRetentionActor.ref("short").run }
    default_message.update!(completed_at: 2.days.ago)
    short_message.update!(completed_at: 2.days.ago)
    SolidObjects.configuration.message_retention_by_actor_type = {
      "short-retention" => 1.day
    }

    assert_equal 1, SolidObjects::MessagePruner.new(now: Time.current).prune
    assert SolidObjects::Message.exists?(default_message.id)
    refute SolidObjects::Message.exists?(short_message.id)
  end

  test "process pruning removes only old stopped records" do
    old_stopped = create_process(shutdown_state: "stopped", stopped_at: 8.days.ago)
    recent_stopped = create_process(shutdown_state: "stopped", stopped_at: 1.day.ago)
    running = create_process(shutdown_state: "running", stopped_at: nil)
    pruner = SolidObjects::ProcessPruner.new(now: Time.current)

    assert_equal 1, pruner.preview
    assert_equal 1, pruner.prune
    refute SolidObjects::Process.exists?(old_stopped.id)
    assert SolidObjects::Process.exists?(recent_stopped.id)
    assert SolidObjects::Process.exists?(running.id)
  end

  test "instance pruning is opt in and previews before deleting" do
    expiring = ExpiringActor.ref("expired")
    retained = RetentionActor.ref("retained")
    expiring.increment
    retained.increment
    expired_instance = expiring_instance("expired")
    expired_instance.update!(last_used_at: 31.days.ago)
    SolidObjects.configuration.instance_retention_by_actor_type = {
      "expiring-retention" => 30.days
    }
    pruner = SolidObjects::InstancePruner.new(now: Time.current)

    assert_equal 1, pruner.preview
    assert SolidObjects::Instance.exists?(expired_instance.id)
    assert_equal 1, pruner.prune
    refute SolidObjects::Instance.exists?(expired_instance.id)
    assert SolidObjects::Instance.where(
      actor_type: "retention",
      actor_id: "retained"
    ).exists?
  end

  test "instance pruning preserves actors with pending mailbox work" do
    reference = ExpiringActor.ref("pending")
    reference.async(:increment, available_at: 1.day.from_now)
    instance = expiring_instance("pending")
    instance.update!(created_at: 31.days.ago, updated_at: 31.days.ago)
    SolidObjects.configuration.instance_retention_by_actor_type = {
      "expiring-retention" => 30.days
    }

    pruner = SolidObjects::InstancePruner.new(now: Time.current)

    assert_equal 0, pruner.preview
    assert_equal 0, pruner.prune
    assert SolidObjects::Instance.exists?(instance.id)
  end

  test "instance pruning preserves actors with scheduled reminders" do
    ExpiringActor.ref("scheduled").schedule_increment
    instance = expiring_instance("scheduled")
    instance.update!(last_used_at: 31.days.ago)
    SolidObjects.configuration.instance_retention_by_actor_type = {
      "expiring-retention" => 30.days
    }

    assert_equal 0, SolidObjects::InstancePruner.new(now: Time.current).prune
    assert SolidObjects::Instance.exists?(instance.id)
  end

  private

  def expiring_instance(actor_id)
    SolidObjects::Instance.find_by!(
      actor_type: "expiring-retention",
      actor_id:
    )
  end

  def completed_message
    yield
    SolidObjects::Message.order(:id).last
  end

  def create_process(shutdown_state:, stopped_at:)
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: 10.days.ago,
      last_heartbeat_at: 10.days.ago,
      metadata: {},
      shutdown_state:,
      stopped_at:
    )
  end
end
