# frozen_string_literal: true

require "database_test_helper"

class ScheduleWithoutOperationTest < ActiveSupport::TestCase
  class Holder < SolidObjects::Actor
    actor_type "schedule-without-operation"

    attribute :status, default: "open"

    def hold
      self.status = "held"
      schedule(at: 10.minutes.from_now, key: "ada").expire
    end

    def hold_without_operation
      self.status = "held"
      schedule(at: 10.minutes.from_now, key: "ada")
      true
    end

    def hold_with_one_operation_missing
      self.status = "held"
      schedule(at: 10.minutes.from_now, key: "ada").expire
      schedule(at: 20.minutes.from_now, key: "grace")
      true
    end

    def hold_with_a_late_operation
      reminder = schedule(at: 10.minutes.from_now, key: "ada")
      self.status = "held"
      reminder.expire
    end

    def expire
      self.status = "open"
    end
  end

  setup do
    SolidObjects.configuration.max_attempts = 3
    SolidObjects.configuration.retry_delay = ->(_) { 0 }
  end

  test "a schedule call with no operation after it fails the message" do
    error = assert_raises(SolidObjects::MessageFailed) { Holder.ref("one").sync.hold_without_operation }

    assert_equal "SolidObjects::ScheduleWithoutOperation", error.details.fetch("class")
    assert_match(/schedule\(at: .*key: "ada"\)/, error.details.fetch("message"))
    assert_match(/call an operation on the result/i, error.details.fetch("message"))
  end

  test "the failed turn commits no state and no reminder, and it does not retry" do
    assert_raises(SolidObjects::MessageFailed) { Holder.ref("one").sync.hold_without_operation }

    assert_empty SolidObjects::Instance.find_by!(actor_id: "one").state
    assert_empty SolidObjects::Reminder.all
    assert_equal 1, SolidObjects::Message.sole.attempt_count
    assert_equal 1, SolidObjects::DeadLetter.count
  end

  test "one schedule call without an operation fails a turn that also has a complete call" do
    error = assert_raises(SolidObjects::MessageFailed) { Holder.ref("one").sync.hold_with_one_operation_missing }

    assert_equal "SolidObjects::ScheduleWithoutOperation", error.details.fetch("class")
    assert_match(/key: "grace"/, error.details.fetch("message"))
    assert_no_match(/key: "ada"/, error.details.fetch("message"))
    assert_empty SolidObjects::Reminder.all
  end

  test "a schedule call with an operation stores its reminder" do
    Holder.ref("one").sync.hold

    assert_equal "held", SolidObjects::Instance.find_by!(actor_id: "one").state.fetch("status")
    assert_equal [ "expire" ], SolidObjects::Reminder.pluck(:operation)
  end

  test "a turn can keep the schedule result and call the operation later" do
    Holder.ref("one").sync.hold_with_a_late_operation

    assert_equal [ "expire" ], SolidObjects::Reminder.pluck(:operation)
  end

  test "a failed turn does not make the next turn of the same actor fail" do
    reference = Holder.ref("one")
    assert_raises(SolidObjects::MessageFailed) { reference.sync.hold_without_operation }

    reference.sync.hold

    assert_equal [ "expire" ], SolidObjects::Reminder.pluck(:operation)
  end
end
