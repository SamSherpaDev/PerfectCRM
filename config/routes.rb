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
  get "inbox/:id", to: "inbox#show", as: :inbox_thread
  resources :conversations, only: %i[show] do
    member do
      post :link
      post :ignore
      post :make_client
      post :make_lead
      post :make_organization
    end
  end
  resources :attachments, only: %i[show] do
    member do
      post :move_to_perfectbook
    end
  end
  resources :mail_imports, only: %i[index new create show] do
    member do
      post :preview
      post :commit
    end
  end
  resources :leads, except: %i[destroy] do
    member do
      post :convert
    end
    resources :notes, only: %i[create]
  end
  resources :clients, except: %i[destroy] do
    collection do
      get "by-perfectbook/:perfectbook_contact_id", action: :by_perfectbook, as: :by_perfectbook
    end
    member do
      patch :archive
      patch :unarchive
    end
    resources :notes, only: %i[create]
  end
  resources :organizations, except: %i[index destroy] do
    resources :notes, only: %i[create]
  end
  get "pipeline", to: "pipeline#show"
  resources :quotes, only: %i[index]
  resources :templates, except: :show do
    collection do
      post :preview, action: :collection_preview
      get :picker
      get :merge
      post :merge, action: :merge_preview
    end
    member do
      post :duplicate
      patch :archive
      patch :unarchive
      patch :move
      post :use
    end
  end
  resource :settings, only: %i[edit update] do
    post :perfectbook_test, on: :collection
    patch :mailbox, on: :collection
    post :mailbox_test, on: :collection
  end
  get "settings/export", to: "exports#show", as: :settings_export
  resources :tasks, only: %i[create] do
    member do
      patch :complete
      patch :snooze
    end
    collection do
      post :create_review_ask
    end
  end
  # Component kit preview (signed-in only, listed nowhere in the rail).
  get "design", to: "design#show"
end
