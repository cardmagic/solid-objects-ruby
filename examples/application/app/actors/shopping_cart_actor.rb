# rbs_inline: enabled

class ShoppingCartActor < SolidObjects::Actor
  attribute :items, default: -> { [] }
  attribute :checkout_status, default: "open"
  attribute :payment_id

  observable :items_count, broadcast: :value do
    items.sum { |item| item.fetch("quantity") }
  end

  observable :subtotal_cents, broadcast: :value do
    items.sum do |item|
      item.fetch("quantity") * item.fetch("unit_price_cents")
    end
  end

  observable :checkout_status

  def add_item(product_id:, unit_price_cents:, quantity: 1)
    item = items.find do |candidate|
      candidate.fetch("product_id") == product_id
    end

    if item
      item["quantity"] += quantity
    else
      items << {
        "product_id" => product_id,
        "unit_price_cents" => unit_price_cents,
        "quantity" => quantity
      }
    end
  end

  def remove_item(product_id:)
    items.reject! do |item|
      item.fetch("product_id") == product_id
    end
  end

  def change_quantity(product_id:, quantity:)
    item = items.find do |candidate|
      candidate.fetch("product_id") == product_id
    end
    return unless item

    item["quantity"] = quantity
  end

  def checkout(payment_id:)
    return unless checkout_status == "open"

    self.checkout_status = "pending"
    self.payment_id = payment_id
    emit(
      :charge_payment,
      payment_id:,
      amount_cents: items.sum do |item|
        item.fetch("quantity") * item.fetch("unit_price_cents")
      end,
      on_success: :payment_succeeded,
      on_failure: :payment_failed
    )
  end

  def payment_succeeded(effect_id:, arguments:, result:)
    return unless checkout_status == "pending"
    return unless arguments.fetch("payment_id") == payment_id

    self.checkout_status = "paid"
  end

  def payment_failed(effect_id:, arguments:, error:)
    return unless checkout_status == "pending"

    self.checkout_status = "payment_failed"
  end
end
