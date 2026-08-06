# frozen_string_literal: true

require "test_helper"

class StateMigrationTest < ActiveSupport::TestCase
  class VersionedActor < SolidObjects::Actor
    actor_type "versioned"
    state_version 3

    migrate_state from: 1, to: 2 do |state|
      state["currency"] = "USD"
      state
    end

    migrate_state from: 2, to: 3 do |state|
      state["locale"] = "en-US"
      state
    end
  end

  test "runs every published migration step in order" do
    migrated = VersionedActor.definition.migrate_state(1, { "total" => 100 })

    assert_equal(
      { "total" => 100, "currency" => "USD", "locale" => "en-US" },
      migrated
    )
  end

  test "refuses stored state newer than the running code" do
    error = assert_raises(SolidObjects::StateMigrationError) do
      VersionedActor.definition.migrate_state(4, {})
    end

    assert_match(/newer than code version 3/, error.message)
  end

  test "refuses a missing historical migration step" do
    actor_class = Class.new(SolidObjects::Actor) do
      actor_type "incomplete-migrations"
      state_version 3

      migrate_state from: 2, to: 3 do |state|
        state
      end
    end

    assert_raises(SolidObjects::StateMigrationError) do
      actor_class.definition.migrate_state(1, {})
    end
  end
end
