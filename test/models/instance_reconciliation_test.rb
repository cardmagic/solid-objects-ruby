# frozen_string_literal: true

require "database_test_helper"

class InstanceReconciliationTest < ActiveSupport::TestCase
  test "bulk reads actor state by logical identity" do
    SolidObjects::Instance.create!(
      actor_type: "UserNudgeActor",
      actor_id: "1",
      state: { "status" => "active" }
    )
    SolidObjects::Instance.create!(
      actor_type: "UserNudgeActor",
      actor_id: "2",
      state: { "status" => "suspended" }
    )

    states = SolidObjects::Instance.states_for(
      actor_type: "UserNudgeActor",
      actor_ids: %w[1 2 3]
    )

    assert_equal(
      {
        "1" => { "status" => "active" },
        "2" => { "status" => "suspended" }
      },
      states
    )
  end

  test "finds quiet actors with no mailbox work or scheduled reminder" do
    lost_alarm = create_instance("lost", last_used_at: 7.hours.ago)
    create_instance("recent", last_used_at: 1.hour.ago)
    ready = create_instance("ready", last_used_at: 7.hours.ago)
    claimed = create_instance("claimed", last_used_at: 7.hours.ago)
    reminded = create_instance("reminded", last_used_at: 7.hours.ago)
    create_ready_message(ready)
    create_claimed_message(claimed)
    SolidObjects::Reminder.create!(
      instance: reminded,
      actor_type: reminded.actor_type,
      actor_id: reminded.actor_id,
      name: "next-evaluation",
      message_name: "evaluate",
      arguments: {},
      next_run_at: 1.day.from_now
    )

    relation = SolidObjects::Instance
      .active(actor_type: "UserNudgeActor")
      .without_pending_work(quiet_for: 6.hours)

    assert_equal [ lost_alarm.id ], relation.pluck(:id)
  end

  test "finds actors whose application owner no longer exists" do
    owner = create_process(id: "existing-owner")
    create_instance(owner.id)
    orphan = create_instance("deleted-owner")
    create_instance("other-type", actor_type: "AnotherActor")

    relation = SolidObjects::Instance.orphaned(
      actor_type: "UserNudgeActor",
      owner: SolidObjects::Process.all
    )

    assert_equal [ orphan.id ], relation.pluck(:id)
  end

  # A cast result carries the connection collation while the column carries the
  # schema's. MySQL refuses to compare two collations, and which one the
  # connection uses is a property of the client: mysql2 negotiates the database
  # default, Trilogy negotiates utf8mb4_general_ci.
  test "compares owner ids in the column's own collation" do
    skip unless database_family == :mysql

    sql = SolidObjects::Instance.orphaned(
      actor_type: "UserNudgeActor",
      owner: SolidObjects::Process.all
    ).to_sql
    collation = SolidObjects::Instance.columns_hash["actor_id"].collation

    assert_includes sql, "COLLATE #{collation}",
      "the cast must be pinned to the column's collation, not the connection's"
  end

  # `CAST(x AS TEXT)` is not valid MySQL, so a MySQL client that falls through
  # to the default produces a SQL error rather than a wrong answer.
  test "casts owner ids per database family rather than per client name" do
    expected = {
      "Mysql2" => "CHAR",
      "Trilogy" => "CHAR",
      "PostgreSQL" => "VARCHAR",
      "SQLite" => "TEXT"
    }

    expected.each do |adapter_name, cast_type|
      assert_equal cast_type, cast_type_for(adapter_name),
        "#{adapter_name} should cast owner ids as #{cast_type}"
    end
  end

  private

  def cast_type_for(adapter_name)
    connection = Data.define(:adapter_name).new(adapter_name:)
    SolidObjects::Instance.define_singleton_method(:connection) { connection }
    SolidObjects::Instance.send(:owner_id_cast_type)
  ensure
    SolidObjects::Instance.singleton_class.send(:remove_method, :connection)
  end

  def create_instance(actor_id, actor_type: "UserNudgeActor", last_used_at: Time.current)
    SolidObjects::Instance.create!(actor_type:, actor_id:, last_used_at:)
  end

  def create_ready_message(instance)
    message = create_message(instance)
    SolidObjects::ReadyMessage.create!(
      message:,
      instance:,
      sequence: message.sequence,
      available_at: Time.current
    )
  end

  def create_claimed_message(instance)
    message = create_message(instance)
    process_record = create_process
    SolidObjects::ClaimedMessage.create!(
      message:,
      instance:,
      process_id: process_record.id,
      activation_token: SecureRandom.uuid,
      activation_generation: 1,
      claimed_at: Time.current
    )
  end

  def create_message(instance)
    SolidObjects::Message.create!(
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      message_name: "evaluate",
      message_kind: "async",
      arguments: {},
      sequence: 1,
      request_id: SecureRandom.uuid,
      max_attempts: 5,
      enqueued_at: Time.current
    )
  end

  def create_process(id: SecureRandom.uuid)
    SolidObjects::Process.create!(
      id:,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )
  end
end
