# frozen_string_literal: true

require_relative "../guides/guide_test_helper"
require_relative "../../examples/compare/game_room/game_room"

class GameRoomTest < ActiveSupport::TestCase
  include SolidObjects::TestHelper

  setup do
    GameRoom.ensure_registered!
  end

  def turn_reminders(room_id)
    SolidObjects::Reminder.where(actor_id: room_id)
  end

  test "moves for one room apply in the order they arrived" do
    room = GameRoom.ref("room-1")
    room.start(players: [ "alice", "bob" ])
    [ [ "alice", "e4", 0 ], [ "bob", "e5", 1 ], [ "alice", "Nf3", 2 ] ].each do |player_id, move, turn_number|
      room.async(idempotency_key: "move-#{turn_number}").play(player_id:, move:, turn_number:)
    end

    drain_solid_objects(roles: [ :actors ])

    assert_equal [ "e4", "e5", "Nf3" ], room.snapshot.moves.map { |entry| entry.fetch("move") }
    assert_equal 3, room.snapshot.turn_number
  end

  test "a move out of turn or for an old turn is rejected and changes nothing" do
    room = GameRoom.ref("room-1")
    room.start(players: [ "alice", "bob" ])
    room.play(player_id: "alice", move: "e4", turn_number: 0)

    assert_equal "not_your_turn", assert_raises(SolidObjects::Rejected) { room.play(player_id: "alice", move: "d4", turn_number: 1) }.code
    assert_equal "stale_turn", assert_raises(SolidObjects::Rejected) { room.play(player_id: "bob", move: "e5", turn_number: 0) }.code
    assert_equal [ "e4" ], room.snapshot.moves.map { |entry| entry.fetch("move") }
  end

  test "a move moves the turn timer, so one room holds one timer" do
    room = GameRoom.ref("room-1")
    room.start(players: [ "alice", "bob" ])

    travel 30.seconds do
      room.play(player_id: "alice", move: "e4", turn_number: 0)
    end

    assert_equal 1, turn_reminders("room-1").count
    assert_in_delta 90.seconds.from_now, turn_reminders("room-1").first.next_run_at, 2
  end

  test "the turn timer fires after a restart and skips the turn" do
    room = GameRoom.ref("room-1")
    room.start(players: [ "alice", "bob" ])

    SolidObjects.reset_caller_process!
    run_due_reminders(now: 61.seconds.from_now)
    drain_solid_objects(roles: [ :actors ])

    assert_equal [ 0 ], room.snapshot.skipped_turns
    assert_equal 1, room.snapshot.turn_number
    assert_equal 1, turn_reminders("room-1").count
  end
end
