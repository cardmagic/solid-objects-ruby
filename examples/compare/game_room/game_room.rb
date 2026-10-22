# rbs_inline: enabled

class GameRoom < SolidObjects::Actor
  TURN_DURATION = 60.seconds

  attribute :players, default: -> { [] }
  attribute :turn_number, default: 0
  attribute :moves, default: -> { [] }
  attribute :skipped_turns, default: -> { [] }

  def start(players:)
    return turn_number if self.players.any?
    reject(:not_enough_players, "The game needs two players") if players.uniq.size < 2

    self.players = players.uniq
    start_turn_timer
    turn_number
  end

  def play(player_id:, move:, turn_number:)
    reject(:not_started, "The game has not started") if players.empty?
    reject(:stale_turn, "That turn already ended") unless turn_number == self.turn_number
    reject(:not_your_turn, "It is not your turn") unless player_id == current_player

    self.moves = moves + [ { "player_id" => player_id, "move" => move, "turn_number" => turn_number } ]
    next_turn
  end

  def turn_timeout(turn_number:)
    return self.turn_number unless turn_number == self.turn_number

    self.skipped_turns = skipped_turns + [ turn_number ]
    next_turn
  end

  private

  def current_player
    players[turn_number % players.size]
  end

  def next_turn
    self.turn_number += 1
    start_turn_timer
    turn_number
  end

  def start_turn_timer
    schedule(at: TURN_DURATION.from_now).turn_timeout(turn_number:)
  end
end
