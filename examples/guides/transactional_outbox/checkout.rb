# rbs_inline: enabled

class Checkout < SolidObjects::Actor
  attribute :status, default: "open"
  attribute :total_cents, default: 0
  attribute :shipment_id, default: nil

  def place(total_cents:)
    return status unless status == "open"

    self.status = "placed"
    self.total_cents = total_cents
    commit_action(:record_order, reference: actor_id, total_cents:)
    emit(:request_shipment, order_reference: actor_id, on_success: :shipment_requested)
    status
  end

  def shipment_requested(effect_id:, arguments:, result:)
    self.status = "shipping"
    self.shipment_id = result.fetch("shipment_id")
  end
end
