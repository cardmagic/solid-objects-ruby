# frozen_string_literal: true

require "database_test_helper"

class AdministrationTest < ActiveSupport::TestCase
  test "requires administration authorization for process inspection" do
    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.administration.processes
    end
  end

  test "returns frozen process snapshots with current liveness" do
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    process = SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {
        "solid_objects_version" => SolidObjects::VERSION,
        "nested" => { "value" => "original" }
      }
    )

    processes = SolidObjects.administration.processes

    snapshot = processes.find { |record| record[:id] == process.id }
    assert_equal "worker", snapshot[:kind]
    assert_equal false, snapshot[:stale]
    assert_predicate processes, :frozen?
    assert_predicate snapshot, :frozen?
    assert_raises(FrozenError) do
      snapshot[:metadata]["nested"]["value"] = "changed"
    end
  end
end
