# frozen_string_literal: true

require "database_test_helper"

class RemindersTest < ActiveSupport::TestCase
  class ExpiringActor < SolidObjects::Actor
    actor_type "expiring"

    attribute :status, default: "active"

    message :schedule do
      remind :expire, at: 1.hour.from_now, arguments: {}
    end

    message :schedule_recurring do
      remind :expire, at: 1.minute.ago, every: 60, arguments: {}
    end

    message :expire do
      state.status = "expired"
    end
  end

  test "persists a reminder in the actor commit" do
    message_reference = ExpiringActor.ref("one").tell(:schedule)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    reminder = SolidObjects::Reminder.find_by!(instance: SolidObjects::Message.find(message_reference.id).instance)
    assert_equal "expire", reminder.name
    assert_equal "expire", reminder.message_name
    assert_equal "scheduled", reminder.status
    assert_operator reminder.next_run_at, :>, Time.current
  ensure
    worker&.stop
  end

  test "converts a due reminder into an ordinary mailbox message" do
    ExpiringActor.ref("one").tell(:schedule)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    reminder = SolidObjects::Reminder.first
    reminder.update!(next_run_at: 1.second.ago)
    scheduler = SolidObjects::ReminderScheduler.new

    assert scheduler.run_once
    assert_equal "completed", reminder.reload.status

    worker.run_until_idle

    assert_equal({ "status" => "expired" }, reminder.instance.reload.state)
  ensure
    scheduler&.stop
    worker&.stop
  end

  test "advances a recurring reminder after enqueueing its callback" do
    ExpiringActor.ref("one").tell(:schedule_recurring)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    scheduler = SolidObjects::ReminderScheduler.new

    assert scheduler.run_once

    reminder = SolidObjects::Reminder.first
    assert_equal "scheduled", reminder.status
    assert_equal 1, reminder.occurrence
    assert_operator reminder.next_run_at, :>, Time.current
  ensure
    scheduler&.stop
    worker&.stop
  end
end
