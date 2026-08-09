# rbs_inline: enabled

SolidObjects::Engine.routes.draw do
  get :components, to: "components#show"
  get "components/batch", to: "components#batch"
  resources :instances, only: %i[index show]
  resources :dead_letters, only: %i[index] do
    post :retry, on: :member
  end
end
