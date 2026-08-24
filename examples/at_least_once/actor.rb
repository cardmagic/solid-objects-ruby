# rbs_inline: enabled

class DeliveryCounter < SolidObjects::Actor
  actor_type "delivery-counter"

  attribute :count, default: 0

  # @rbs () -> Integer
  def deliver
    self.count += 1
    emit :record
    count
  end
end
