# rbs_inline: enabled

require "database_test_helper"

class InstancePrunerTest < ActiveSupport::TestCase
  test "retention uses the last use or creation time with a strict cutoff" do
    now = Time.utc(2026, 9, 16, 12)
    cutoff = now - 30.days
    SolidObjects.configuration.instance_retention_by_actor_type = { "expiry-test" => 30.days }
    expired = [
      create_instance("unused-old", created_at: cutoff - 1.second, last_used_at: nil),
      create_instance("used-old", created_at: now, last_used_at: cutoff - 1.second)
    ]
    retained = [
      create_instance("unused-boundary", created_at: cutoff, last_used_at: nil),
      create_instance("unused-recent", created_at: now, last_used_at: nil),
      create_instance("used-boundary", created_at: cutoff - 1.day, last_used_at: cutoff),
      create_instance("used-recent", created_at: cutoff - 1.day, last_used_at: now)
    ]
    pruner = SolidObjects::InstancePruner.new(now:)

    assert_equal 2, pruner.preview
    assert_equal 2, pruner.prune
    assert_empty SolidObjects::Instance.where(id: expired.map(&:id))
    assert_equal retained.map(&:id).sort, SolidObjects::Instance.order(:id).pluck(:id)
  end

  test "MySQL finds expired candidates through the cleanup index" do
    skip "requires a MySQL query plan" unless database_family == :mysql

    now = Time.utc(2026, 9, 16, 12)
    SolidObjects.configuration.instance_retention_by_actor_type = { "expiry-test" => 30.days }
    SolidObjects::Instance.insert_all!(Array.new(2_000) { |index|
      { actor_type: "expiry-test", actor_id: "recent-#{index}", state: {},
        created_at: now, updated_at: now, last_used_at: now }
    })
    connection = SolidObjects::Instance.connection
    connection.execute("ANALYZE TABLE solid_objects_instances")
    statements = []
    subscriber = ->(*arguments) { statements << arguments.last[:sql].to_s }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      assert_equal 0, SolidObjects::InstancePruner.new(now:).prune
    end

    query = statements.find { |sql| sql.match?(/\ASELECT .* FROM `solid_objects_instances` /) }
    assert query, "the candidate lookup was not captured"
    plan = connection.select_all("EXPLAIN FORMAT=TRADITIONAL #{query}").to_a
      .find { |row| row["table"] == "solid_objects_instances" }

    assert plan, "the candidate table was not present in the query plan"
    assert_equal "idx_so_instances_cleanup", plan&.fetch("key")
    assert_operator plan&.fetch("rows").to_i, :<, 20
  end

  private

  # @rbs (String, created_at: Time, last_used_at: Time?) -> SolidObjects::Instance
  def create_instance(actor_id, created_at:, last_used_at:)
    SolidObjects::Instance.create!(actor_type: "expiry-test", actor_id:, created_at:, last_used_at:)
  end
end
