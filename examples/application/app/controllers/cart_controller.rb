# rbs_inline: enabled

class CartController < ApplicationController
  # @rbs () -> void
  def show
    @cart = ShoppingCartActor.ref(current_user.id)
  end

  # @rbs () -> void
  def add_item
    ShoppingCartActor.ref(current_user.id).tell(
      :add_item,
      product_id: params.require(:product_id),
      unit_price_cents: params.require(:unit_price_cents).to_i,
      quantity: params.fetch(:quantity, 1).to_i,
      authorization_context: self
    )
    redirect_to cart_path
  end

  # @rbs () -> void
  def remove_item
    current_cart.tell(
      :remove_item,
      product_id: params.require(:product_id),
      authorization_context: self
    )
    redirect_to cart_path
  end

  # @rbs () -> void
  def change_quantity
    current_cart.tell(
      :change_quantity,
      product_id: params.require(:product_id),
      quantity: params.require(:quantity).to_i,
      authorization_context: self
    )
    redirect_to cart_path
  end

  # @rbs () -> void
  def checkout
    current_cart.tell(
      :checkout,
      payment_id: SecureRandom.uuid,
      authorization_context: self
    )
    redirect_to cart_path
  end

  private

  # @rbs () -> SolidObjects::Reference
  def current_cart
    ShoppingCartActor.ref(current_user.id)
  end
end
