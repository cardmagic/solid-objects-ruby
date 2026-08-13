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
      schedule(at: 1.second.ago).finish_work
      emit :record_test_helper_effect
    end

    def finish_work
      self.value += 1
    end

    def start_future_work(run_at:)
      schedule(at: Time.iso8601(run_at)).finish_work
    end

    def start_recurring_work(run_at:)
      schedule(at: Time.iso8601(run_at), every: 1.minute).finish_work
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

  # The helper used to delete instances and let the database cascade remove
  # everything else. Where the cascade does not fire, rows survive into the
  # next test pointing at an instance that no longer exists, and a test that
  # reads them sees another test's data.
  test "reset actors clears actor-owned rows without the database cascade" do
    skip unless database_family == :sqlite

    instance = create_actor_owned_rows
    without_foreign_keys do
      SolidObjects::TestHelper.reset_actors!
    end

    remaining = SolidObjects::TestHelper.actor_owned_models.reject { |model| model.count.zero? }
    assert_empty remaining.map(&:table_name),
      "these tables survived a reset that could not rely on the cascade"
    refute_nil instance
  end

  # A table added later is only covered if the helper is told about it, and the
  # cascade would hide the omission on every database that enforces it.
  test "every actor-owned table is in the reset list" do
    owned = SolidObjects::Record.connection.tables
      .grep(/\Asolid_objects_/)
      .reject { |table| table == "solid_objects_test_domain_records" }
      .sort
    listed = SolidObjects::TestHelper.actor_owned_models.map(&:table_name)

    assert_equal owned, (listed + [ SolidObjects::Process.table_name ]).sort,
      "a Solid Objects table is missing from reset_actors!"
  end

  test "drain actor messages processes queued work deterministically" do
    test_case = ActorTestCase.new("unused")
    message_reference = HelperActor.ref("async").async.increment

    assert_equal 1, test_case.drain_solid_objects(roles: [ :actors ])
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
    message_reference = HelperActor.ref("workflow").async.start_work

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

  test "run due reminders uses an explicit test time" do
    test_case = ActorTestCase.new("unused")
    run_at = 5.minutes.from_now
    reference = HelperActor.ref("future-work")
    reference.async.start_future_work(run_at: run_at.iso8601(6))
    test_case.drain_solid_objects(roles: [ :actors ])

    assert_equal 0, test_case.run_due_reminders(now: run_at - 1.second)
    assert_equal 1, test_case.run_due_reminders(now: run_at)
    assert_equal 1, test_case.drain_solid_objects(roles: [ :actors ])
    assert_equal({ "value" => 1 }, SolidObjects::Instance.find_by!(actor_id: "future-work").state)
  end

  test "run due reminders advances recurrence from the explicit test time" do
    test_case = ActorTestCase.new("unused")
    run_at = 5.minutes.from_now
    reference = HelperActor.ref("recurring-work")
    reference.async.start_recurring_work(run_at: run_at.iso8601(6))
    test_case.drain_solid_objects(roles: [ :actors ])

    test_now = run_at + 5.minutes
    assert_equal 1, test_case.run_due_reminders(now: test_now)

    reminder = SolidObjects::Reminder.find_by!(actor_id: "recurring-work")
    assert_operator reminder.next_run_at, :>, test_now
    assert_operator reminder.next_run_at, :<=, test_now + 1.minute
  end

  private

  # One row in every actor-owned table, so an omission from the reset list
  # shows up as a surviving table rather than as a passing test.
  def create_actor_owned_rows
    now = Time.current
    instance = SolidObjects::Instance.create!(
      actor_type: "reset-probe",
      actor_id: "one",
      state: {},
      state_version: 1
    )
    message = SolidObjects::Message.create!(
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      operation: "noop",
      delivery_mode: "async",
      arguments: {},
      sequence: 1,
      max_attempts: 1,
      request_id: SecureRandom.uuid,
      enqueued_at: now,
      available_at: now
    )
    SolidObjects::ReadyMessage.create!(message:, instance:, sequence: 1, available_at: now)
    SolidObjects::ClaimedMessage.create!(
      message:,
      instance:,
      activation_generation: 1,
      claimed_at: now
    )
    SolidObjects::Reminder.create!(
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      name: "probe",
      operation: "noop",
      arguments: {},
      next_run_at: now,
      status: "scheduled"
    )
    SolidObjects::Effect.create!(
      instance:,
      message:,
      effect_id: SecureRandom.uuid,
      name: "probe",
      arguments: {},
      max_attempts: 1,
      available_at: now
    )
    SolidObjects::Broadcast.create!(
      instance:,
      message:,
      broadcast_id: SecureRandom.uuid,
      observable_name: "probe",
      value: {},
      state_version: 1,
      activation_generation: 1,
      available_at: now
    )
    SolidObjects::DeadLetter.create!(
      instance:,
      message:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      operation: "noop",
      arguments: {},
      attempts: 1,
      exception_class: "RuntimeError",
      exception_message: "probe",
      backtrace: [],
      first_failed_at: now,
      last_failed_at: now
    )
    instance
  end

  def without_foreign_keys
    connection = SolidObjects::Record.connection
    connection.execute("PRAGMA foreign_keys = OFF")
    yield
  ensure
    connection.execute("PRAGMA foreign_keys = ON")
  end
end
