# rbs_inline: enabled

class Event < ApplicationRecord
  def hold_seat_unsafely
    return false if seats_available.zero?

    update!(seats_available: seats_available - 1)
    true
  end

  def hold_seat
    self.class.where(id:).where("seats_available > 0")
      .update_all("seats_available = seats_available - 1") == 1
  end
end
