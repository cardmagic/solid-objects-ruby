# rbs_inline: enabled

Rails.application.routes.draw do
  resource :cart, only: :show do
    post :add_item
    post :remove_item
    post :change_quantity
    post :checkout
  end

  resources :chat_rooms, only: :show do
    member do
      post :join
      post :leave
      post :create_message
    end
  end

  mount SolidObjects::Engine => "/solid_objects"
end
