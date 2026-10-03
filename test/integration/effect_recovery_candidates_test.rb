# frozen_string_literal: true

require "database_test_helper"

class EffectRecoveryCandidatesTest < ActiveSupport::TestCase
  class CandidateActor < SolidObjects::Actor
    actor_type "effect-recovery-candidates"

    def run
    end
  end

  setup do
    @message = SolidObjects::Message.find(CandidateActor.ref("one").async.run.id)
  end

  test "recovery candidates are abandoned processing effects with a recovery operation in effect order" do
    now = SolidObjects.database_adapter.database_clock_now
    threshold = SolidObjects.configuration.process_alive_threshold
    live_owner = create_process(last_heartbeat_at: now)
    stale_owner = create_process(last_heartbeat_at: now - (threshold * 3))
    unowned = create_effect("00000000-0000-4000-8000-000000000009", status: "processing")
    create_effect("00000000-0000-4000-8000-000000000001", status: "processing", owner: live_owner)
    abandoned = create_effect("00000000-0000-4000-8000-000000000002", status: "processing", owner: stale_owner)
    create_effect("00000000-0000-4000-8000-000000000003", status: "processing", owner: stale_owner, recovery_timeout: threshold * 10)
    create_effect("00000000-0000-4000-8000-000000000004", status: "processing", retired_at: now)
    create_effect("00000000-0000-4000-8000-000000000005", status: "processing", recovery_operation: nil)
    create_effect("00000000-0000-4000-8000-000000000006", status: "pending")
    create_effect("00000000-0000-4000-8000-000000000007", status: "completed")

    assert_equal [ abandoned, unowned ], recovery_candidates.map(&:effect_id)
  end

  test "recovery candidates stop at the claim scan limit" do
    SolidObjects.configuration.claim_scan_limit = 1
    create_effect("00000000-0000-4000-8000-000000000002", status: "processing")
    first = create_effect("00000000-0000-4000-8000-000000000001", status: "processing")

    assert_equal [ first ], recovery_candidates.map(&:effect_id)
  end

  test "SQLite finds recovery candidates through processing effects when most effects are complete" do
    skip "requires a SQLite query plan" unless database_family == :sqlite

    now = Time.current
    effect_ids = Array.new(3_000) { SecureRandom.uuid }
    connection = SolidObjects::Record.connection
    restoring_sqlite_statistics(connection) do
      SolidObjects::Effect.insert_all!(effect_ids.map { |effect_id|
        { message_id: @message.id, instance_id: @message.instance_id, effect_id:, name: "work", arguments: {},
          status: "completed", max_attempts: 3, available_at: now, completed_at: now, created_at: now, updated_at: now }
      })
      SolidObjects::EffectRecovery.insert_all!(effect_ids.last(300).map { |effect_id|
        { effect_id:, instance_id: @message.instance_id, recovery_operation: "recover", status_operation: "status",
          created_at: now, updated_at: now }
      })
      connection.execute("ANALYZE")
      poll_statistics = connection.select_value("SELECT stat FROM sqlite_stat1 WHERE idx = 'idx_so_effects_poll'")

      assert_equal 3_000, poll_statistics.split[1].to_i

      plan = connection.select_all("EXPLAIN QUERY PLAN #{recovery_candidates.to_sql}").map { |row| row["detail"] }

      assert_match(/\ASEARCH #{SolidObjects::Effect.table_name} USING INDEX idx_so_effects_poll \(status=\?\)/, plan.first, plan.join("\n"))
      assert plan.none? { |step| step.start_with?("SCAN ") }, plan.join("\n")
    end
  end

  private

  def recovery_candidates
    SolidObjects::EffectRecoveryCoordinator.new.send(:recovery_candidates)
  end

  def create_effect(effect_id, status:, owner: nil, recovery_operation: "recover", recovery_timeout: nil, retired_at: nil)
    SolidObjects::Effect.create!(
      message: @message,
      instance: @message.instance,
      effect_id:,
      name: "work",
      arguments: {},
      status:,
      max_attempts: 3,
      available_at: Time.current,
      claimed_by: owner&.id,
      claimed_at: owner && Time.current
    )
    SolidObjects::EffectRecovery.create!(
      effect_id:,
      instance: @message.instance,
      recovery_operation:,
      status_operation: "status",
      recovery_timeout:,
      retired_at:
    )
    effect_id
  end

  def create_process(last_heartbeat_at:)
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "effect",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: last_heartbeat_at,
      last_heartbeat_at:,
      metadata: {}
    )
  end
end
