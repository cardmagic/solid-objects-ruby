# rbs_inline: enabled

class TicketSale < SolidObjects::Actor
  attribute :available, default: 1
  attribute :holds, default: -> { {} }

  def hold(buyer:)
    return { held: false, available: } if available.zero? || holds.key?(buyer)

    self.available -= 1
    self.holds = holds.merge(buyer => Time.current.to_i)
    schedule(at: 10.minutes.from_now, key: buyer).expire(buyer:)
    { held: true, available: }
  end

  def expire(buyer:)
    return available unless holds.key?(buyer)

    self.holds = holds.except(buyer)
    self.available += 1
  end
end
