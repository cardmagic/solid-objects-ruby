# frozen_string_literal: true

require "database_test_helper"
require "solid_objects/test_helper"

class PublicTestHelperTest < ActiveSupport::TestCase
  class HelperActor < SolidObjects::Actor
    actor_type "test-helper"

    attribute :value, default: 0

    def increment
      self.value += 1
    end

    observable :value

    def start_work
      self.value += 1
      schedule :finish_work, at: 1.second.ago, arguments: {}
      emit :record_test_helper_effect
    end

    def finish_work
      self.value += 1
    end
  end

  class ActorTestCase < ActiveSupport::TestCase
    class_attribute :use_transactional_tests, default: true

    include SolidObjects::TestHelper
  end

  test "including the helper disables transactional tests" do
    refute ActorTestCase.use_transactional_tests
  end

  test "reset actors removes durable rows and caller registrations" do
    HelperActor.ref("one").increment

    assert SolidObjects::Instance.exists?
    assert SolidObjects::Process.exists?

    SolidObjects::TestHelper.reset_actors!

    assert_empty SolidObjects::Instance.all
    assert_empty SolidObjects::Process.all
  end

  test "drain actor messages processes queued work deterministically" do
    test_case = ActorTestCase.new("unused")
    message_reference = HelperActor.ref("async").async(:increment)

    assert_equal 1, test_case.drain_solid_objects
    assert_equal "completed", message_reference.status
  end

  test "drain processes reminders effects actor callbacks and broadcasts" do
    effects = []
    broadcasts = []
    SolidObjects.register_effect(:record_test_helper_effect) do |_arguments, context|
      effects << context.source_message_id
    end
    SolidObjects.configuration.broadcast_adapter = ->(broadcast) { broadcasts << broadcast.observable_name }
    test_case = ActorTestCase.new("unused")
    message_reference = HelperActor.ref("workflow").async(:start_work)

    assert_operator test_case.drain_solid_objects, :>=, 4

    instance = SolidObjects::Instance.find_by!(
      actor_type: "test-helper",
      actor_id: "workflow"
    )
    assert_equal({ "value" => 2 }, instance.state)
    assert_equal "completed", message_reference.status
    assert_equal [ message_reference.id ], effects
    assert_equal [ "value", "value" ], broadcasts
    assert_equal [ "completed" ], SolidObjects::Effect.pluck(:status)
    assert_equal [ "completed" ], SolidObjects::Reminder.pluck(:status)
    assert_equal [ "delivered", "delivered" ], SolidObjects::Broadcast.order(:id).pluck(:status)
  end

  test "drain rejects unknown roles" do
    test_case = ActorTestCase.new("unused")

    error = assert_raises(ArgumentError) do
      test_case.drain_solid_objects(roles: [ :unknown ])
    end

    assert_includes error.message, "unknown"
  end
end
