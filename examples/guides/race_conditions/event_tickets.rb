# rbs_inline: enabled

class EventTickets < SolidObjects::Actor
  HOLD_DURATION = 10.minutes

  attribute :opened, default: false
  attribute :seats_available, default: 0
  attribute :holds, default: -> { {} }
  attribute :sold, default: -> { [] }
  attribute :title, default: ""
  attribute :revision, default: 0

  def open_sales(seats:)
    return seats_available if opened

    self.opened = true
    self.seats_available = seats
  end

  def hold(buyer:, hold_id:)
    release_expired_holds
    return { held: true, hold_id: } if holds.dig(buyer, "hold_id") == hold_id
    return { held: false, reason: "already_held" } if holds.key?(buyer)
    return { held: false, reason: "sold_out" } if seats_available.zero?

    deadline = HOLD_DURATION.from_now
    self.seats_available -= 1
    self.holds = holds.merge(buyer => { "hold_id" => hold_id, "expires_at" => deadline.to_i })
    schedule(at: deadline, key: buyer).expire(buyer:, hold_id:, expires_at: deadline.to_i)
    { held: true, hold_id: }
  end

  def confirm(buyer:, hold_id:)
    return { confirmed: true } if sold.include?(hold_id)

    release_expired_holds
    reject(:no_hold, "The hold expired or does not exist") unless holds.dig(buyer, "hold_id") == hold_id

    self.holds = holds.except(buyer)
    self.sold = sold + [ hold_id ]
    unschedule(:expire, key: buyer)
    { confirmed: true }
  end

  def expire(buyer:, hold_id:, expires_at:)
    return seats_available unless holds[buyer] == { "hold_id" => hold_id, "expires_at" => expires_at }

    self.holds = holds.except(buyer)
    self.seats_available += 1
  end

  def update_details(title:, base_revision:)
    reject(:stale_revision, "Reload the event and try again") unless base_revision == revision

    self.title = title
    self.revision += 1
  end

  private

  def release_expired_holds
    expired_buyers = holds.select { |_buyer, hold| hold.fetch("expires_at") <= Time.current.to_i }.keys
    self.holds = holds.except(*expired_buyers)
    self.seats_available += expired_buyers.length
  end
end
