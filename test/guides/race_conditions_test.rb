# frozen_string_literal: true

require_relative "guide_test_helper"
require_relative "../../examples/guides/race_conditions/event"
require_relative "../../examples/guides/race_conditions/event_tickets"

class RaceConditionsGuideTest < ActiveSupport::TestCase
  include SolidObjects::TestHelper
  include GuideTestSupport

  setup do
    GuideSchema.reset
    EventTickets.ensure_registered!
  end

  test "two requests that loaded the same event both hold the last seat" do
    event = Event.create!(seats_available: 1)
    first_request = Event.find(event.id)
    second_request = Event.find(event.id)

    assert first_request.hold_seat_unsafely
    assert second_request.hold_seat_unsafely
    assert_equal 0, event.reload.seats_available
  end

  test "a conditional update holds no more seats than the event has" do
    event = Event.create!(seats_available: 3)

    results = concurrently(10, prepare: ->(_index) { Event.find(event.id) }) do |request_copy|
      request_copy.hold_seat
    end

    assert_equal 3, results.count(true)
    assert_equal 0, event.reload.seats_available
  end

  test "the actor holds no more seats than it has under concurrent requests" do
    tickets = EventTickets.ref("event-concurrent")
    tickets.open_sales(seats: 3)

    results = concurrently(10) do |index|
      tickets.hold(buyer: "buyer-#{index}", hold_id: "hold-#{index}")
    end

    assert_equal 3, results.count { |result| result.fetch("held") }
    assert_equal 0, tickets.snapshot.seats_available
    assert_equal 3, tickets.snapshot.holds.length
  end

  test "a hold expires after a restart when its reminder is due" do
    tickets = EventTickets.ref("event-restart")
    tickets.open_sales(seats: 1)
    tickets.hold(buyer: "ada", hold_id: "hold-1")
    SolidObjects.reset_caller_process!

    assert_equal 0, run_due_reminders(now: 9.minutes.from_now)
    assert_equal 1, run_due_reminders(now: 11.minutes.from_now)
    drain_solid_objects(roles: [ :actors ])

    assert_equal 1, tickets.snapshot.seats_available
    assert_empty tickets.snapshot.holds
  end

  test "a stale expiry for an old hold changes nothing" do
    tickets = EventTickets.ref("event-stale")
    tickets.open_sales(seats: 1)
    tickets.hold(buyer: "ada", hold_id: "hold-1")
    first_deadline = tickets.snapshot.holds.dig("ada", "expires_at")
    run_due_reminders(now: 11.minutes.from_now)
    drain_solid_objects(roles: [ :actors ])
    tickets.hold(buyer: "ada", hold_id: "hold-2")

    tickets.expire(buyer: "ada", hold_id: "hold-1", expires_at: first_deadline)

    assert_equal 0, tickets.snapshot.seats_available
    assert_equal "hold-2", tickets.snapshot.holds.dig("ada", "hold_id")
  end

  test "a retried hold and a retried confirmation apply once" do
    tickets = EventTickets.ref("event-retry")
    tickets.open_sales(seats: 2)

    holds = 2.times.map { tickets.hold(buyer: "ada", hold_id: "hold-1") }
    confirmations = 2.times.map { tickets.confirm(buyer: "ada", hold_id: "hold-1") }

    assert_equal [ true, true ], holds.map { |result| result.fetch("held") }
    assert_equal [ true, true ], confirmations.map { |result| result.fetch("confirmed") }
    assert_equal 1, tickets.snapshot.seats_available
    assert_equal [ "hold-1" ], tickets.snapshot.sold
    assert_nil reminder_due_at(actor_id: "event-retry", operation: :expire, key: "ada")
  end

  test "a confirmation after the hold expired is rejected" do
    tickets = EventTickets.ref("event-late")
    tickets.open_sales(seats: 1)
    tickets.hold(buyer: "ada", hold_id: "hold-1")
    run_due_reminders(now: 11.minutes.from_now)
    drain_solid_objects(roles: [ :actors ])

    error = assert_raises(SolidObjects::Rejected) { tickets.confirm(buyer: "ada", hold_id: "hold-1") }

    assert_equal "no_hold", error.code
    assert_equal 1, tickets.snapshot.seats_available
  end

  test "a hold past its deadline cannot be confirmed and frees its seat before the reminder runs" do
    tickets = EventTickets.ref("event-deadline")
    tickets.open_sales(seats: 1)
    tickets.hold(buyer: "ada", hold_id: "hold-1")

    travel 11.minutes do
      error = assert_raises(SolidObjects::Rejected) { tickets.confirm(buyer: "ada", hold_id: "hold-1") }

      assert_equal "no_hold", error.code
      assert tickets.hold(buyer: "grace", hold_id: "hold-2").fetch("held")
    end
  end

  test "an old expiry queued after a retry with the same hold ID keeps the new hold" do
    tickets = EventTickets.ref("event-retry-after-deadline")
    tickets.open_sales(seats: 1)
    tickets.hold(buyer: "ada", hold_id: "hold-1")
    first_deadline = tickets.snapshot.holds.dig("ada", "expires_at")

    travel 11.minutes do
      assert tickets.hold(buyer: "ada", hold_id: "hold-1").fetch("held")
      tickets.expire(buyer: "ada", hold_id: "hold-1", expires_at: first_deadline)

      assert_equal 0, tickets.snapshot.seats_available
      assert_equal "hold-1", tickets.snapshot.holds.dig("ada", "hold_id")
    end
  end

  test "serial execution alone does not stop a stale form, so a revision check does" do
    tickets = EventTickets.ref("event-details")
    tickets.update_details(title: "Spring show", base_revision: 0)

    error = assert_raises(SolidObjects::Rejected) do
      tickets.update_details(title: "Old title from a stale form", base_revision: 0)
    end

    assert_equal "stale_revision", error.code
    assert_equal "Spring show", tickets.snapshot.title
  end
end
