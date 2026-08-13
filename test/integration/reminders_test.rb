# frozen_string_literal: true

require "database_test_helper"

class RemindersTest < ActiveSupport::TestCase
  class ExpiringActor < SolidObjects::Actor
    actor_type "expiring"

    attribute :status, default: "active"

    def configure_expiration
      schedule(at: 1.hour.from_now).expire
    end

    def schedule_recurring
      schedule(at: 1.minute.ago, every: 60).expire
    end

    def expire
      self.status = "expired"
    end
  end

  class QueueActor < SolidObjects::Actor
    actor_type "reminder-queue"

    attribute :entries, default: -> { [] }

    def add(wait_until:)
      self.entries = entries + [ wait_until ]
      schedule(at: Time.at(wait_until).utc).deliver
    end

    def arm(name:, wait_until:)
      schedule(at: Time.at(wait_until).utc).public_send(name.to_sym)
    end

    def deliver
      self.entries = []
    end

    def sweep
    end
  end

  # The pattern the reminders guide recommends instead of one alarm per item.
  # It is documented, so it is executed here rather than only read.
  class QueueDrainActor < SolidObjects::Actor
    actor_type "reminder-drain"

    attribute :entries, default: -> { [] }
    attribute :delivered, default: -> { [] }

    def add(wait_until:)
      self.entries = (entries + [ wait_until ]).sort
      arm_next
    end

    def deliver
      now = Time.now.to_i
      due, pending = entries.partition { |wait_until| wait_until <= now }
      self.delivered = delivered + due
      self.entries = pending
      arm_next
    end

    private

    def arm_next
      earliest = entries.first
      return unless earliest

      schedule(at: Time.at(earliest).utc).deliver
    end
  end

  test "one alarm drains every due item and arms the next" do
    reference = QueueDrainActor.ref("table")
    due = 10.seconds.ago.to_i
    later = 1.hour.from_now.to_i
    reference.async.add(wait_until: due)
    reference.async.add(wait_until: later)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    scheduler = SolidObjects::ReminderScheduler.new

    assert scheduler.run_once, "the earliest item should have armed the alarm"
    worker.run_until_idle

    state = SolidObjects::Instance.find_by!(actor_type: "reminder-drain").state
    assert_equal [ due ], state.fetch("delivered")
    assert_equal [ later ], state.fetch("entries")
    reminder = SolidObjects::Reminder.find_by!(actor_type: "reminder-drain")
    assert_equal later, reminder.next_run_at.to_i,
      "the handler should have armed the next item before finishing"
  ensure
    scheduler&.stop
    worker&.stop
  end

  test "persists a reminder in the actor commit" do
    message_reference = ExpiringActor.ref("one").async.configure_expiration
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
    ExpiringActor.ref("one").async.configure_expiration
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
    ExpiringActor.ref("one").async.schedule_recurring
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

  test "does not expose the old reminder DSL" do
    actor = SolidObjects::State.new(ExpiringActor.definition.state_definition).then do |state|
      ExpiringActor.new(actor_id: "one", state:)
    end

    assert_not actor.respond_to?(:remind, true)
  end

  # A reminder is one named alarm per actor, so a second schedule with the same
  # name moves the existing alarm rather than adding one. An actor that arms a
  # reminder per queued item therefore keeps only the last, which is silent
  # data loss if the caller expected an alarm each.
  test "a second schedule with the same name moves the existing reminder" do
    reference = QueueActor.ref("table")
    first = 1.hour.from_now.to_i
    second = 2.hours.from_now.to_i
    reference.async.add(wait_until: first)
    reference.async.add(wait_until: second)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    reminders = SolidObjects::Reminder.where(actor_type: "reminder-queue")
    assert_equal 1, reminders.count,
      "two entries but one named reminder, which is the whole hazard"
    assert_equal second, reminders.sole.next_run_at.to_i
  end

  test "reminders with different names on one actor coexist" do
    reference = QueueActor.ref("table")
    reference.async.arm(name: "deliver", wait_until: 1.hour.from_now.to_i)
    reference.async.arm(name: "sweep", wait_until: 2.hours.from_now.to_i)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal %w[deliver sweep],
      SolidObjects::Reminder.where(actor_type: "reminder-queue").order(:name).pluck(:name)
  end

  test "the same reminder name on another actor is a separate reminder" do
    QueueActor.ref("one").async.add(wait_until: 1.hour.from_now.to_i)
    QueueActor.ref("two").async.add(wait_until: 2.hours.from_now.to_i)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal 2, SolidObjects::Reminder.where(actor_type: "reminder-queue").count
  end

  # The replacement is otherwise invisible, and finding it in production means
  # finding it by noticing something never happened.
  test "moving a reminder is instrumented" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.reminder.replaced") do |event|
      events << event.payload
    end
    reference = QueueActor.ref("table")
    reference.async.add(wait_until: 1.hour.from_now.to_i)
    reference.async.add(wait_until: 2.hours.from_now.to_i)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal 1, events.length, "only the replacement should report"
    assert_equal "reminder-queue", events.sole.fetch(:actor_type)
    assert_equal "table", events.sole.fetch(:actor_id)
    assert_equal "deliver", events.sole.fetch(:name)
    refute_equal events.sole.fetch(:previous_run_at), events.sole.fetch(:next_run_at)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "scheduling reports moves to its caller rather than announcing them" do
    executor = SolidObjects::Executor.allocate
    instance = SolidObjects::Instance.create!(
      actor_type: "reminder-queue",
      actor_id: "unit",
      state: {},
      state_version: 1
    )
    intent = SolidObjects::Actor::ReminderIntent.new(
      name: "deliver",
      at: 1.hour.from_now,
      arguments: {},
      interval_seconds: nil,
      missed_policy: "latest"
    )
    later = SolidObjects::Actor::ReminderIntent.new(
      name: "deliver",
      at: 2.hours.from_now,
      arguments: {},
      interval_seconds: nil,
      missed_policy: "latest"
    )
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.reminder.replaced") do |event|
      events << event.payload
    end

    assert_empty executor.send(:schedule_reminders, instance, [ intent ]),
      "a first schedule moves nothing"
    moves = executor.send(:schedule_reminders, instance, [ later ])

    assert_equal 1, moves.length, "the move should be returned to the caller"
    assert_equal "deliver", moves.sole.fetch(:name)
    assert_empty events,
      "scheduling must not announce a move that the enclosing turn may roll back"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "rescheduling to the same time reports nothing" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.reminder.replaced") do |event|
      events << event.payload
    end
    wait_until = 1.hour.from_now.to_i
    reference = QueueActor.ref("table")
    reference.async.add(wait_until:)
    reference.async.add(wait_until:)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_empty events,
      "a reschedule that moves nothing is not the hazard worth reporting"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end
end
