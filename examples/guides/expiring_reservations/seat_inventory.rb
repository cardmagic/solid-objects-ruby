# rbs_inline: enabled

class SeatInventory < SolidObjects::Actor
  HOLD_DURATION = 15.minutes
  EXTENSION = 5.minutes
  MAX_EXTENSIONS = 2

  attribute :capacity, default: 0
  attribute :holds, default: -> { {} }
  attribute :confirmed, default: -> { {} }

  query :seats_left do
    seats_available
  end

  def open_show(capacity:)
    self.capacity = capacity if self.capacity.zero?
    seats_available
  end

  def hold(hold_id:, buyer:, seats:)
    return hold_result(hold_id) if holds.key?(hold_id)
    return { status: "confirmed" } if confirmed.key?(hold_id)
    reject(:not_enough_seats, "Only #{seats_available} seats are left") if seats > seats_available

    deadline = HOLD_DURATION.from_now
    self.holds = holds.merge(
      hold_id => { "buyer" => buyer, "seats" => seats, "expires_at" => deadline.to_i, "extensions" => 0 }
    )
    schedule(at: deadline, key: hold_id).expire(hold_id:, expires_at: deadline.to_i)
    hold_result(hold_id)
  end

  def extend_hold(hold_id:)
    hold = holds[hold_id]
    reject(:no_hold, "The hold expired or does not exist") unless hold
    reject(:extension_limit, "The hold cannot be extended again") if hold.fetch("extensions") >= MAX_EXTENSIONS

    deadline = Time.at(hold.fetch("expires_at")) + EXTENSION
    self.holds = holds.merge(
      hold_id => hold.merge("expires_at" => deadline.to_i, "extensions" => hold.fetch("extensions") + 1)
    )
    schedule(at: deadline, key: hold_id).expire(hold_id:, expires_at: deadline.to_i)
    hold_result(hold_id)
  end

  def confirm(hold_id:)
    return { status: "confirmed" } if confirmed.key?(hold_id)

    hold = holds[hold_id]
    reject(:no_hold, "The hold expired or does not exist") unless hold

    self.holds = holds.except(hold_id)
    self.confirmed = confirmed.merge(hold_id => hold.fetch("seats"))
    unschedule(:expire, key: hold_id)
    { status: "confirmed" }
  end

  def expire(hold_id:, expires_at:)
    return seats_available unless holds.dig(hold_id, "expires_at") == expires_at

    self.holds = holds.except(hold_id)
    seats_available
  end

  private

  def seats_available
    capacity - holds.values.sum { |hold| hold.fetch("seats") } - confirmed.values.sum
  end

  def hold_result(hold_id)
    { status: "held", expires_at: holds.dig(hold_id, "expires_at") }
  end
end
