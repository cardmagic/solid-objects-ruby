# rbs_inline: enabled

SolidObjects::Engine.routes.draw do
  resources :instances, only: %i[index show]
  resources :dead_letters, only: %i[index] do
    post :retry, on: :member
  end
end
