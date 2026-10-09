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
    return { held: true, hold_id: } if holds.dig(buyer, "hold_id") == hold_id
    return { held: false, reason: "already_held" } if holds.key?(buyer)
    return { held: false, reason: "sold_out" } if seats_available.zero?

    self.seats_available -= 1
    self.holds = holds.merge(buyer => { "hold_id" => hold_id })
    schedule(at: HOLD_DURATION.from_now, key: buyer).expire(buyer:, hold_id:)
    { held: true, hold_id: }
  end

  def confirm(buyer:, hold_id:)
    return { confirmed: true } if sold.include?(hold_id)
    reject(:no_hold, "The hold expired or does not exist") unless holds.dig(buyer, "hold_id") == hold_id

    self.holds = holds.except(buyer)
    self.sold = sold + [ hold_id ]
    unschedule(:expire, key: buyer)
    { confirmed: true }
  end

  def expire(buyer:, hold_id:)
    return seats_available unless holds.dig(buyer, "hold_id") == hold_id

    self.holds = holds.except(buyer)
    self.seats_available += 1
  end

  def update_details(title:, base_revision:)
    reject(:stale_revision, "Reload the event and try again") unless base_revision == revision

    self.title = title
    self.revision += 1
  end
end
