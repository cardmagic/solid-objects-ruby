# rbs_inline: enabled

class Order < ApplicationRecord
  def self.place_and_enqueue!(reference:, total_cents:)
    order = create!(reference:, total_cents:)
    ShipmentJob.perform_later(order_id: order.id)
    order
  end

  def self.place_with_outbox!(reference:, total_cents:)
    transaction do
      order = create!(reference:, total_cents:)
      OutboxMessage.create!(name: "request_shipment", arguments: { "order_id" => order.id })
      order
    end
  end
end
