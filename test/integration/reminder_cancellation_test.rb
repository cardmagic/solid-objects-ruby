# frozen_string_literal: true

require "database_test_helper"

class ReminderCancellationTest < ActiveSupport::TestCase
  class TrialActor < SolidObjects::Actor
    actor_type "cancel-trial"

    attribute :status, default: "trialing"
    attribute :expirations, default: 0
    attribute :handle, default: nil

    def start_trial
      self.handle = schedule(at: 1.hour.from_now).trial_expired
    end

    def start_recurring
      self.handle = schedule(at: 1.minute.ago, every: 60).trial_expired
    end

    def convert
      self.status = "active"
      unschedule(:trial_expired)
    end

    def convert_by_handle
      self.status = "active"
      unschedule(handle)
    end

    def convert_then_reschedule
      unschedule(:trial_expired)
      schedule(at: 3.hours.from_now).trial_expired
    end

    def convert_then_raise
      unschedule(:trial_expired)
      raise "turn failed"
    end

    def read_unknown
      reminder(:no_such_operation)
    end

    def list_unknown
      reminders(:no_such_operation)
    end

    def cancel_unknown
      unschedule(:no_such_operation)
    end

    def cancel_all_unknown
      unschedule_all(:no_such_operation)
    end

    def convert_with_bad_handle
      unschedule({ "not_a_reminder" => "x" })
    end

    def convert_with_handle_and_key
      unschedule({ "reminder_name" => "trial_expired" }, key: "extra")
    end

    def trial_expired
      self.expirations += 1
      self.status = "expired"
    end

    def stop_after_first
      self.expirations += 1
      unschedule(:trial_expired)
    end
  end

  class ChaseActor < SolidObjects::Actor
    actor_type "cancel-chase"

    attribute :chased, default: -> { [] }

    def chase_many(ids:)
      ids.each { |id| schedule(at: 1.hour.from_now, key: id).chase_carrier(carrier_id: id) }
      schedule(at: 1.hour.from_now).audit
    end

    def shipped(carrier_id:)
      unschedule(:chase_carrier, key: carrier_id)
    end

    def stop_chasing
      unschedule_all(:chase_carrier)
    end

    def chase_carrier(carrier_id:)
      self.chased = chased + [ carrier_id ]
    end

    def audit
    end
  end

  class HookActor < SolidObjects::Actor
    actor_type "cancel-hooks"

    attribute :seen_on_activate, default: nil

    observable :armed do
      reminder(:ping)&.name
    end

    on_activate do
      self.seen_on_activate = reminder(:ping)&.name
    end

    def arm
      schedule(at: Time.utc(2030, 1, 1)).ping
    end

    def fail_turn
      raise "turn failed"
    end

    def record_seen
      self.seen_on_activate = reminder(:ping)&.name
    end

    def ping
    end
  end

  class InspectorActor < SolidObjects::Actor
    actor_type "cancel-inspector"

    attribute :seen, default: nil

    def arm
      schedule(at: Time.utc(2030, 1, 1), every: 90).ping
    end

    def read_next_run
      found = reminder(:ping)
      self.seen = found && {
        "name" => found.name,
        "operation" => found.operation,
        "next_run_at" => found.next_run_at.to_i,
        "interval_seconds" => found.interval_seconds.to_f,
        "handle" => found.handle
      }
    end

    def read_after_staged_schedule
      schedule(at: Time.utc(2031, 1, 1)).ping
      self.seen = { "next_run_at" => reminder(:ping).next_run_at.to_i }
    end

    def read_after_staged_cancel
      unschedule(:ping)
      self.seen = { "present" => !reminder(:ping).nil? }
    end

    def count_keyed
      self.seen = { "count" => reminders(:ping).length }
    end

    def arm_keyed
      schedule(at: Time.utc(2030, 1, 1), key: "a").ping
      schedule(at: Time.utc(2030, 1, 1), key: "b").ping
    end

    def ping
    end
  end

  def drain
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    worker.stop
  end

  def reminders_for(actor_type)
    SolidObjects::Reminder.where(actor_type:).order(:name)
  end

  def state_of(actor_type)
    SolidObjects::Instance.find_by!(actor_type:).state
  end

  test "schedule returns a reminder handle naming the reminder" do
    TrialActor.ref("alice").async.start_trial
    drain

    assert_equal({ "reminder_name" => "trial_expired" }, state_of("cancel-trial").fetch("handle"))
  end

  test "a cancelled reminder does not fire" do
    reference = TrialActor.ref("alice")
    reference.async.start_trial
    drain
    reference.async.convert
    drain

    assert_empty reminders_for("cancel-trial")
    assert_equal 0, state_of("cancel-trial").fetch("expirations")
  end

  test "a cancelled recurring reminder stops firing" do
    reference = TrialActor.ref("alice")
    reference.async.start_recurring
    drain
    scheduler = SolidObjects::ReminderScheduler.new
    scheduler.run_once
    drain

    assert_equal 1, state_of("cancel-trial").fetch("expirations")

    reference.async.convert
    drain

    assert_empty reminders_for("cancel-trial")
    assert_not scheduler.run_once, "no reminder should remain due"
  ensure
    scheduler&.stop
  end

  test "a recurring reminder that cancels itself fires once" do
    TrialActor.ref("alice").async.start_recurring
    drain
    # Replace the handler so the first firing cancels the schedule.
    SolidObjects::Reminder.find_by!(actor_type: "cancel-trial").update!(operation: "stop_after_first")
    scheduler = SolidObjects::ReminderScheduler.new
    scheduler.run_once
    drain

    assert_equal 1, state_of("cancel-trial").fetch("expirations")
    assert_empty reminders_for("cancel-trial")
    assert_not scheduler.run_once
  ensure
    scheduler&.stop
  end

  test "cancelling an absent reminder raises nothing" do
    TrialActor.ref("alice").async.convert
    drain

    assert_equal "active", state_of("cancel-trial").fetch("status")
    assert_empty reminders_for("cancel-trial")
  end

  test "a turn that raises leaves the reminder scheduled" do
    reference = TrialActor.ref("alice")
    reference.async.start_trial
    drain
    reference.async.convert_then_raise
    drain

    assert_equal 1, reminders_for("cancel-trial").count
  end

  test "cancel then schedule in one turn leaves one reminder at the new time" do
    reference = TrialActor.ref("alice")
    reference.async.start_trial
    drain
    reference.async.convert_then_reschedule
    drain

    reminders = reminders_for("cancel-trial")
    assert_equal 1, reminders.count
    assert_operator reminders.first.next_run_at, :>, 2.hours.from_now
  end

  test "cancelling by handle removes the same reminder as cancelling by name" do
    reference = TrialActor.ref("alice")
    reference.async.start_trial
    drain
    reference.async.convert_by_handle
    drain

    assert_empty reminders_for("cancel-trial")
  end

  test "a handle stored in state cancels after a reactivation" do
    reference = TrialActor.ref("alice")
    reference.async.start_trial
    drain

    assert_equal 1, reminders_for("cancel-trial").count

    reference.async.convert_by_handle
    drain

    assert_empty reminders_for("cancel-trial")
  end

  test "an unknown operation is refused when reading rather than reported absent" do
    SolidObjects.configuration.max_attempts = 1
    reference = TrialActor.ref("alice")
    reference.async.start_trial
    drain
    reference.async.read_unknown
    reference.async.list_unknown
    drain

    assert_equal 2, SolidObjects::DeadLetter.where(actor_type: "cancel-trial").count
    assert_equal [ "SolidObjects::UnknownMessage" ],
      SolidObjects::DeadLetter.where(actor_type: "cancel-trial").distinct.pluck(:exception_class)
  end

  test "an unknown operation is refused rather than cancelling nothing" do
    SolidObjects.configuration.max_attempts = 1
    reference = TrialActor.ref("alice")
    reference.async.start_trial
    drain
    reference.async.cancel_unknown
    reference.async.cancel_all_unknown
    drain

    assert_equal 2, SolidObjects::DeadLetter.where(actor_type: "cancel-trial").count
    assert_equal [ "SolidObjects::UnknownMessage" ],
      SolidObjects::DeadLetter.where(actor_type: "cancel-trial").distinct.pluck(:exception_class)
    assert_equal 1, reminders_for("cancel-trial").count
  end

  test "a malformed handle is rejected" do
    SolidObjects.configuration.max_attempts = 1
    TrialActor.ref("alice").async.convert_with_bad_handle
    drain

    dead_letter = SolidObjects::DeadLetter.find_by!(actor_type: "cancel-trial")
    assert_equal "SolidObjects::InvalidPayload", dead_letter.exception_class
    assert_match(/reminder handle/, dead_letter.exception_message)
  end

  test "a handle passed with a key is refused" do
    SolidObjects.configuration.max_attempts = 1
    TrialActor.ref("alice").async.convert_with_handle_and_key
    drain

    assert_equal "ArgumentError",
      SolidObjects::DeadLetter.find_by!(actor_type: "cancel-trial").exception_class
  end

  test "a keyed cancel removes one key and leaves its siblings" do
    reference = ChaseActor.ref("truck")
    reference.async.chase_many(ids: %w[a b c])
    drain
    reference.async.shipped(carrier_id: "b")
    drain

    assert_equal %w[audit chase_carrier:a chase_carrier:c], reminders_for("cancel-chase").pluck(:name)
  end

  test "unschedule_all removes every key of one operation" do
    reference = ChaseActor.ref("truck")
    reference.async.chase_many(ids: %w[a b c])
    drain
    reference.async.stop_chasing
    drain

    assert_equal %w[audit], reminders_for("cancel-chase").pluck(:name)
  end

  test "an activation hook reads the schedule rather than reporting none" do
    reference = HookActor.ref("one")
    reference.async.arm
    drain
    SolidObjects::Instance.update_all(activation_owner_id: nil, activation_token: nil, activation_expires_at: nil)
    reference.async.ping
    drain

    assert_equal "ping", state_of("cancel-hooks").fetch("seen_on_activate")
  end

  test "an observable reads the schedule rather than reporting none" do
    reference = HookActor.ref("one")
    reference.async.arm
    drain

    snapshot = SolidObjects::ActorSnapshot.new(reference)

    assert_equal "ping", snapshot.observable_values.fetch("armed")
  end

  test "an actor restored after a failed turn still reads its schedule" do
    SolidObjects.configuration.max_attempts = 1
    reference = HookActor.ref("one")
    reference.async.arm
    drain
    # Both messages run in one worker pass, so the activation that the failure
    # rebuilt is the one that serves the read.
    reference.async.fail_turn
    reference.async.record_seen
    drain

    assert_equal "ping", state_of("cancel-hooks").fetch("seen_on_activate")
  end

  test "a cancel that lands on a claimed occurrence does not fail the scheduler" do
    reference = TrialActor.ref("alice")
    reference.async.start_recurring
    drain
    scheduler = SolidObjects::ReminderScheduler.new
    claimed = scheduler.send(:claim_next, now: Time.current)

    assert claimed, "the recurring reminder should be claimable"

    reference.async.convert
    drain

    assert_nil scheduler.send(:enqueue, claimed, now: Time.current)
    assert_equal 0, state_of("cancel-trial").fetch("expirations")
  ensure
    scheduler&.stop
  end

  test "inspection reports the next run time and interval" do
    reference = InspectorActor.ref("one")
    reference.async.arm
    drain
    reference.async.read_next_run
    drain

    seen = state_of("cancel-inspector").fetch("seen")
    assert_equal "ping", seen.fetch("name")
    assert_equal "ping", seen.fetch("operation")
    assert_equal Time.utc(2030, 1, 1).to_i, seen.fetch("next_run_at")
    assert_in_delta 90.0, seen.fetch("interval_seconds"), 0.001
    assert_equal({ "reminder_name" => "ping" }, seen.fetch("handle"))
  end

  test "inspection reports nothing for an unscheduled reminder" do
    InspectorActor.ref("one").async.read_next_run
    drain

    assert_nil state_of("cancel-inspector").fetch("seen")
  end

  test "inspection sees a schedule staged earlier in the same turn" do
    InspectorActor.ref("one").async.read_after_staged_schedule
    drain

    assert_equal Time.utc(2031, 1, 1).to_i,
      state_of("cancel-inspector").fetch("seen").fetch("next_run_at")
  end

  test "inspection sees a cancel staged earlier in the same turn" do
    reference = InspectorActor.ref("one")
    reference.async.arm
    drain
    reference.async.read_after_staged_cancel
    drain

    assert_equal false, state_of("cancel-inspector").fetch("seen").fetch("present")
  end

  test "inspection lists every key of one operation" do
    reference = InspectorActor.ref("one")
    reference.async.arm_keyed
    drain
    reference.async.count_keyed
    drain

    assert_equal 2, state_of("cancel-inspector").fetch("seen").fetch("count")
  end
end
