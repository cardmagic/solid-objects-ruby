# frozen_string_literal: true

require "database_test_helper"

class ActorCodeWriteGuardTest < ActiveSupport::TestCase
  class ObservableWritingActor < SolidObjects::Actor
    actor_type "observable-writing"

    attribute :value, default: 0

    observable :value do
      SolidObjectsTestDomainRecord.create!(name: "observable")
      value
    end

    def increment
      self.value += 1
    end
  end

  class ActivatingActor < SolidObjects::Actor
    actor_type "activating-writing"

    on_activate do
      SolidObjectsTestDomainRecord.create!(name: "activate")
    end

    def run
      "ran"
    end
  end

  class DeactivatingActor < SolidObjects::Actor
    actor_type "deactivating-writing"

    on_deactivate do
      SolidObjectsTestDomainRecord.create!(name: "deactivate")
    end

    def run
      "ran"
    end
  end

  class MigratingActor < SolidObjects::Actor
    actor_type "migrating-writing"

    state_version 2

    migrate_state from: 1, to: 2 do |state|
      SolidObjectsTestDomainRecord.create!(name: "migration")
      state
    end

    def run
      "ran"
    end
  end

  test "observable writes fail the message without persisting" do
    error = assert_raises(SolidObjects::MessageFailed) do
      ObservableWritingActor.ref("one").increment
    end

    assert_equal "SolidObjects::ApplicationWriteForbidden", error.details.fetch("class")
    assert_empty SolidObjectsTestDomainRecord.all
    assert_equal 1, SolidObjects::Message.find(error.message_id).attempt_count
  end

  test "activation hook writes fail before actor code runs" do
    error = assert_raises(SolidObjects::ApplicationWriteForbidden) do
      ActivatingActor.ref("one").run
    end

    assert_equal "on_activate", error.message_name
    assert_empty SolidObjectsTestDomainRecord.all
    assert_equal "ready", SolidObjects::MessageReference.from_message(SolidObjects::Message.last).status
  end

  test "activation write failures do not crash a worker loop" do
    message_reference = ActivatingActor.ref("worker").async.run
    worker = SolidObjects::Worker.new

    assert_equal 0, worker.run_once
    assert_equal "ready", message_reference.status
    assert_empty SolidObjectsTestDomainRecord.all
  ensure
    worker&.stop
  end

  test "deactivation hook writes cannot replace a committed result" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe(
      "solid_objects.activation.deactivation_failed"
    ) { |event| events << event.payload }

    assert_equal "ran", DeactivatingActor.ref("one").run
    assert_empty SolidObjectsTestDomainRecord.all
    assert_nil SolidObjects::Instance.find_by!(actor_type: "deactivating-writing").activation_owner_id
    assert_predicate events, :one?
    assert_equal "SolidObjects::ApplicationWriteForbidden", events.first.fetch(:error_class)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "state migration writes fail before activation" do
    SolidObjects::Instance.create!(
      actor_type: "migrating-writing",
      actor_id: "one",
      state: {},
      state_version: 1
    )

    error = assert_raises(SolidObjects::ApplicationWriteForbidden) do
      MigratingActor.ref("one").run
    end

    assert_equal "state_migration", error.message_name
    assert_empty SolidObjectsTestDomainRecord.all
  end
end
