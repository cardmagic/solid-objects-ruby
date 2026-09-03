# frozen_string_literal: true

require "database_test_helper"

class SchemaConstraintsTest < ActiveSupport::TestCase
  test "creates durable history and narrow execution membership tables" do
    expected_tables = %w[
      solid_objects_broadcasts
      solid_objects_claimed_messages
      solid_objects_dead_letters
      solid_objects_effects
      solid_objects_instances
      solid_objects_messages
      solid_objects_processes
      solid_objects_ready_messages
      solid_objects_reminders
    ]

    assert_empty expected_tables - ActiveRecord::Base.connection.tables
  end

  test "keeps execution status out of the durable message record" do
    columns = ActiveRecord::Base.connection.columns("solid_objects_messages").map(&:name)

    assert_not_includes columns, "status"
    assert_includes columns, "completed_at"
    assert_includes columns, "attempt_count"
    assert_includes columns, "rejection"
    assert_includes columns, "rejected_at"
  end

  test "persists a monotonic actor state revision" do
    column = ActiveRecord::Base.connection.columns("solid_objects_instances").find do |candidate|
      candidate.name == "state_revision"
    end

    assert column
    assert_equal 0, column.default.to_i
    refute column.null
  end

  test "uses only ordinary indexes for execution membership" do
    indexes = %w[
      solid_objects_ready_messages
      solid_objects_claimed_messages
    ].flat_map { |table| ActiveRecord::Base.connection.indexes(table) }

    assert indexes.all? { |index| index.where.nil? }
  end

  test "indexes each polling query in delivery order" do
    expected_indexes = {
      "solid_objects_effects" => %w[status available_at id],
      "solid_objects_broadcasts" => %w[status available_at id],
      "solid_objects_reminders" => %w[status next_run_at id]
    }

    expected_indexes.each do |table, columns|
      indexes = ActiveRecord::Base.connection.indexes(table).map(&:columns)

      assert_includes indexes, columns
    end
  end

  test "links every runtime claim owner to the process registry" do
    expected_claim_foreign_keys = {
      "solid_objects_claimed_messages" => "process_id",
      "solid_objects_reminders" => "claimed_by",
      "solid_objects_effects" => "claimed_by",
      "solid_objects_broadcasts" => "claimed_by"
    }

    expected_claim_foreign_keys.each do |table, column|
      foreign_keys = ActiveRecord::Base.connection.foreign_keys(table)

      assert foreign_keys.any? { |foreign_key| foreign_key.column == column }
    end
  end

  test "enforces unique actor identity" do
    SolidObjects::Instance.create!(actor_type: "cart", actor_id: "alice")

    assert_raises(ActiveRecord::RecordNotUnique) do
      SolidObjects::Instance.create!(actor_type: "cart", actor_id: "alice")
    end
  end

  test "enforces per-actor sequence uniqueness" do
    instance = SolidObjects::Instance.create!(actor_type: "cart", actor_id: "alice")
    attributes = {
      instance:,
      actor_type: "cart",
      actor_id: "alice",
      operation: "add",
      delivery_mode: "async",
      arguments: {},
      sequence: 1,
      request_id: SecureRandom.uuid,
      max_attempts: 5,
      enqueued_at: Time.current
    }
    SolidObjects::Message.create!(**attributes)

    assert_raises(ActiveRecord::RecordNotUnique) do
      SolidObjects::Message.create!(**attributes.merge(request_id: SecureRandom.uuid))
    end
  end

  test "allows only one claimed message per actor instance" do
    instance = SolidObjects::Instance.create!(actor_type: "cart", actor_id: "alice")
    process_record = SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )
    first_message = create_message_for(instance, sequence: 1)
    second_message = create_message_for(instance, sequence: 2)
    SolidObjects::ClaimedMessage.create!(
      message: first_message,
      instance:,
      process_id: process_record.id,
      activation_token: SecureRandom.uuid,
      activation_generation: 1,
      claimed_at: Time.current
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      SolidObjects::ClaimedMessage.create!(
        message: second_message,
        instance:,
        process_id: process_record.id,
        activation_token: SecureRandom.uuid,
        activation_generation: 1,
        claimed_at: Time.current
      )
    end
  end

  test "removes execution membership when durable history is removed" do
    message = create_message
    SolidObjects::ReadyMessage.create!(
      message:,
      instance: message.instance,
      sequence: message.sequence,
      available_at: Time.current
    )

    message.destroy!

    assert_empty SolidObjects::ReadyMessage.where(message_id: message.id)
  end

  private

  def create_message
    instance = SolidObjects::Instance.create!(actor_type: "cart", actor_id: SecureRandom.uuid)
    create_message_for(instance, sequence: 1)
  end

  def create_message_for(instance, sequence:)
    SolidObjects::Message.create!(
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      operation: "add",
      delivery_mode: "async",
      arguments: {},
      sequence:,
      request_id: SecureRandom.uuid,
      max_attempts: 5,
      enqueued_at: Time.current
    )
  end
end
