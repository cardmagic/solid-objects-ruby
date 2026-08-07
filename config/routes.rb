# rbs_inline: enabled

SolidObjects::Engine.routes.draw do
  get :components, to: "components#show"
  resources :instances, only: %i[index show]
  resources :dead_letters, only: %i[index] do
    post :retry, on: :member
  end
end
