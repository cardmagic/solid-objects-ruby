# rbs_inline: enabled

class ShoppingCartActor < SolidObjects::Actor
  attribute :items, default: -> { [] }
  attribute :checkout_status, default: "open"
  attribute :payment_id

  observable :items_count do
    state.items.sum { |item| item.fetch("quantity") }
  end

  observable :subtotal_cents do
    state.items.sum do |item|
      item.fetch("quantity") * item.fetch("unit_price_cents")
    end
  end

  observable :checkout_status

  message :add_item do |product_id:, unit_price_cents:, quantity: 1|
    item = state.items.find do |candidate|
      candidate.fetch("product_id") == product_id
    end

    if item
      item["quantity"] += quantity
    else
      state.items << {
        "product_id" => product_id,
        "unit_price_cents" => unit_price_cents,
        "quantity" => quantity
      }
    end
  end

  message :remove_item do |product_id:|
    state.items.reject! do |item|
      item.fetch("product_id") == product_id
    end
  end

  message :change_quantity do |product_id:, quantity:|
    item = state.items.find do |candidate|
      candidate.fetch("product_id") == product_id
    end
    return unless item

    item["quantity"] = quantity
  end

  message :checkout do |payment_id:|
    return unless state.checkout_status == "open"

    state.checkout_status = "pending"
    state.payment_id = payment_id
    emit(
      :charge_payment,
      payment_id:,
      amount_cents: state.items.sum do |item|
        item.fetch("quantity") * item.fetch("unit_price_cents")
      end,
      on_success: :payment_succeeded,
      on_failure: :payment_failed
    )
  end

  message :payment_succeeded do |effect_id:, result:|
    return unless state.checkout_status == "pending"
    return unless result.fetch("payment_id") == state.payment_id

    state.checkout_status = "paid"
  end

  message :payment_failed do |effect_id:, error:|
    return unless state.checkout_status == "pending"

    state.checkout_status = "payment_failed"
  end

  query :items do
    state.items
  end
end
