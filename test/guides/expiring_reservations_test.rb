# frozen_string_literal: true

require_relative "guide_test_helper"
require_relative "../../examples/guides/expiring_reservations/seat_inventory"

class ExpiringReservationsGuideTest < ActiveSupport::TestCase
  include SolidObjects::TestHelper
  include GuideTestSupport

  setup do
    SeatInventory.ensure_registered!
  end

  test "concurrent holds never take more seats than the show has" do
    show = SeatInventory.ref("show-concurrent")
    show.open_show(capacity: 5)

    results = concurrently(8) do |index|
      show.hold(hold_id: "hold-#{index}", buyer: "buyer-#{index}", seats: 1).fetch("status")
    rescue SolidObjects::Rejected => rejection
      rejection.code
    end

    assert_equal 5, results.count("held")
    assert_equal 3, results.count("not_enough_seats")
    assert_equal 0, show.seats_left
  end

  test "a retried hold takes its seats once" do
    show = SeatInventory.ref("show-retry")
    show.open_show(capacity: 4)

    2.times { show.hold(hold_id: "hold-1", buyer: "ada", seats: 3) }

    assert_equal 1, show.seats_left
  end

  test "extending a hold moves its reminder to the new deadline" do
    show = SeatInventory.ref("show-extend")
    show.open_show(capacity: 2)
    held = show.hold(hold_id: "hold-1", buyer: "ada", seats: 2)

    extended = show.extend_hold(hold_id: "hold-1")

    assert_equal held.fetch("expires_at") + SeatInventory::EXTENSION.to_i, extended.fetch("expires_at")
    assert_equal extended.fetch("expires_at"),
      reminder_due_at(actor_id: "show-extend", operation: :expire, key: "hold-1").to_i
    assert_equal 0, run_due_reminders(now: 16.minutes.from_now)
    assert_equal 0, show.seats_left
    assert_equal 1, run_due_reminders(now: 21.minutes.from_now)
    drain_solid_objects(roles: [ :actors ])
    assert_equal 2, show.seats_left
  end

  test "an expiry for the old deadline changes nothing after an extension" do
    show = SeatInventory.ref("show-stale")
    show.open_show(capacity: 2)
    held = show.hold(hold_id: "hold-1", buyer: "ada", seats: 2)
    show.extend_hold(hold_id: "hold-1")

    show.expire(hold_id: "hold-1", expires_at: held.fetch("expires_at"))

    assert_equal 0, show.seats_left
  end

  test "a hold can be extended only a limited number of times" do
    show = SeatInventory.ref("show-limit")
    show.open_show(capacity: 1)
    show.hold(hold_id: "hold-1", buyer: "ada", seats: 1)
    SeatInventory::MAX_EXTENSIONS.times { show.extend_hold(hold_id: "hold-1") }

    error = assert_raises(SolidObjects::Rejected) { show.extend_hold(hold_id: "hold-1") }

    assert_equal "extension_limit", error.code
  end

  test "a retried confirmation applies once and cancels the expiry" do
    show = SeatInventory.ref("show-confirm")
    show.open_show(capacity: 3)
    show.hold(hold_id: "hold-1", buyer: "ada", seats: 2)

    results = 2.times.map { show.confirm(hold_id: "hold-1").fetch("status") }

    assert_equal [ "confirmed", "confirmed" ], results
    assert_nil reminder_due_at(actor_id: "show-confirm", operation: :expire, key: "hold-1")
    assert_equal 1, show.seats_left
  end

  test "a confirmation after the hold expired is rejected" do
    show = SeatInventory.ref("show-late")
    show.open_show(capacity: 1)
    show.hold(hold_id: "hold-1", buyer: "ada", seats: 1)
    run_due_reminders(now: 16.minutes.from_now)
    drain_solid_objects(roles: [ :actors ])

    error = assert_raises(SolidObjects::Rejected) { show.confirm(hold_id: "hold-1") }

    assert_equal "no_hold", error.code
    assert_equal 1, show.seats_left
  end

  test "a hold past its deadline cannot be confirmed or extended before the reminder runs" do
    show = SeatInventory.ref("show-deadline")
    show.open_show(capacity: 2)
    show.hold(hold_id: "hold-1", buyer: "ada", seats: 2)

    travel 16.minutes do
      assert_equal "no_hold", assert_raises(SolidObjects::Rejected) { show.confirm(hold_id: "hold-1") }.code
      assert_equal "no_hold", assert_raises(SolidObjects::Rejected) { show.extend_hold(hold_id: "hold-1") }.code
      assert_equal 2, show.seats_left
    end
  end

  test "a hold for zero seats or a negative number of seats is rejected" do
    show = SeatInventory.ref("show-invalid")
    show.open_show(capacity: 5)

    [ 0, -5 ].each do |seats|
      error = assert_raises(SolidObjects::Rejected) { show.hold(hold_id: "hold-#{seats}", buyer: "ada", seats:) }
      assert_equal "invalid_seats", error.code
    end
    assert_equal 5, show.seats_left
  end

  test "a hold that falls due while the runtime is stopped expires after a restart" do
    show = SeatInventory.ref("show-restart")
    show.open_show(capacity: 1)
    show.hold(hold_id: "hold-1", buyer: "ada", seats: 1)
    SolidObjects.reset_caller_process!

    run_due_reminders(now: 2.hours.from_now)
    drain_solid_objects(roles: [ :actors ])

    assert_equal 1, show.seats_left
  end
end
