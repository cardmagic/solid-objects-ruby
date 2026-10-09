# rbs_inline: enabled

class OutboxMessage < ApplicationRecord
  JOBS = { "request_shipment" => ShipmentJob }.freeze

  scope :pending, -> { where(delivered_at: nil).order(:id) }

  def self.relay(limit: 100)
    pending.limit(limit).each do |message|
      JOBS.fetch(message.name).perform_later(**message.arguments.symbolize_keys)
      message.update!(delivered_at: Time.current)
    end
  end
end
