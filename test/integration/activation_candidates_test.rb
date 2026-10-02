# frozen_string_literal: true

require "database_test_helper"

class ActivationCandidatesTest < ActiveSupport::TestCase
  class CandidateActor < SolidObjects::Actor
    actor_type "activation-candidates"

    def run
    end
  end

  test "claimed candidates skip paused and live leases in claim order" do
    now = SolidObjects.database_adapter.database_now
    owner = create_process
    expired = claim_message("expired", claimed_at: now - 40.seconds, owner:, lease_expires_at: now - 1.second)
    unleased = claim_message("unleased", claimed_at: now - 30.seconds)
    first_tie = claim_message("first-tie", claimed_at: now - 20.seconds)
    second_tie = claim_message("second-tie", claimed_at: now - 20.seconds)
    unexpiring = claim_message("unexpiring", claimed_at: now - 10.seconds, owner:)
    claim_message("paused", claimed_at: now - 50.seconds, paused_at: now - 1.minute)
    claim_message("leased", claimed_at: now - 60.seconds, owner:, lease_expires_at: now + 1.minute)

    assert_equal [ expired, unleased, first_tie, second_tie, unexpiring ], claimed_instance_ids(now)
  end

  test "claimed candidates stop at the claim scan limit" do
    now = SolidObjects.database_adapter.database_now
    SolidObjects.configuration.claim_scan_limit = 2
    oldest = claim_message("oldest", claimed_at: now - 30.seconds)
    older = claim_message("older", claimed_at: now - 20.seconds)
    claim_message("newest", claimed_at: now - 10.seconds)

    assert_equal [ oldest, older ], claimed_instance_ids(now)
  end

  test "SQLite reads claimed candidates from the claimed messages when they have no statistics" do
    skip "requires a SQLite query plan" unless database_family == :sqlite

    now = SolidObjects.database_adapter.database_now
    SolidObjects::Instance.insert_all!(Array.new(3_000) { |index|
      { actor_type: "activation-candidates", actor_id: "idle-#{index}", state: {}, created_at: now, updated_at: now }
    })
    connection = SolidObjects::Record.connection
    connection.execute("ANALYZE")
    analyzed_tables = connection.select_values("SELECT DISTINCT tbl FROM sqlite_stat1")

    assert_includes analyzed_tables, SolidObjects::Instance.table_name
    refute_includes analyzed_tables, SolidObjects::ClaimedMessage.table_name

    plan = sqlite_query_plan(connection, SolidObjects::ClaimedMessage.table_name) { claimed_instance_ids(now) }

    assert_match(/\A(SCAN|SEARCH) #{SolidObjects::ClaimedMessage.table_name}\b/, plan.first, plan.join("\n"))
    assert plan.none? { |step| step.start_with?("SCAN #{SolidObjects::Instance.table_name}") }, plan.join("\n")
  ensure
    connection&.execute("DELETE FROM sqlite_stat1")
    connection&.execute("ANALYZE sqlite_schema")
  end

  private

  def claimed_instance_ids(now)
    SolidObjects::ActivationManager.new(owner_id: SecureRandom.uuid).send(:claimed_instance_ids, now)
  end

  def claim_message(actor_id, claimed_at:, owner: nil, lease_expires_at: nil, paused_at: nil)
    message = SolidObjects::Message.find(CandidateActor.ref(actor_id).async.run.id)
    SolidObjects::ReadyMessage.where(message:).delete_all
    message.instance.update!(
      activation_owner_id: owner&.id,
      activation_token: owner && SecureRandom.uuid,
      activation_expires_at: lease_expires_at,
      paused_at:
    )
    SolidObjects::ClaimedMessage.create!(message:, instance: message.instance, activation_generation: 1, claimed_at:)
    message.instance_id
  end

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

  def sqlite_query_plan(connection, table_name)
    statements = []
    subscriber = ->(*arguments) { statements << arguments.last }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    statement = statements.find { |payload| payload[:sql].match?(/\ASELECT .* FROM "#{table_name}"/) }
    assert statement, "the #{table_name} query was not captured"

    connection.select_all("EXPLAIN QUERY PLAN #{statement[:sql]}", "SQL", statement[:binds]).map { |row| row["detail"] }
  end
end
