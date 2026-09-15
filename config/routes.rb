Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "today#show"
  get "sign-in", to: "sessions#new", as: :sign_in
  get "auth/google_oauth2/callback", to: "sessions#create"
  get "auth/failure", to: "sessions#failure"
  delete "sign-out", to: "sessions#destroy", as: :sign_out

  # Rail navigation: see README.md, "Navigation".
  get "inbox", to: "inbox#index"
  resources :clients, only: %i[index]
  get "pipeline", to: "pipeline#show"
  resources :quotes, only: %i[index]
  resources :templates do
    collection do
      post :preview, action: :collection_preview
      get :picker
      get :merge
      post :merge, action: :merge_preview
    end
    member do
      get :preview
      post :duplicate
      patch :archive
      patch :unarchive
      patch :move
      post :use
    end
  end
  resource :settings, only: %i[edit update] do
    post :perfectbook_test, on: :collection
  end

end
