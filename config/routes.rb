Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Website-form intake API (public; per-request auth, no sign-in).
  # Contract: docs/leads-intake.md.
  namespace :api do
    namespace :v1 do
      scope module: :leads do
        match "leads/intake", to: "intakes#preflight", via: :options
        post "leads/intake", to: "intakes#create"
        match "leads/intake/details", to: "details#preflight", via: :options
        post "leads/intake/details", to: "details#create"
        post "leads/:id/verdict", to: "verdicts#create"
      end
    end
  end

  # Defines the root path route ("/")
  root "today#show"
  get "sign-in", to: "sessions#new", as: :sign_in
  get "auth/google_oauth2/callback", to: "sessions#create"
  get "auth/microsoft/callback", to: "microsoft_auth#callback", as: :microsoft_callback
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
  resources :document_handoffs, only: %i[new create]
  resources :mail_imports, only: %i[index new create show] do
    member do
      match :preview, via: %i[get post]
      post :commit
    end
  end
  resources :leads, except: %i[destroy] do
    member do
      post :convert
      patch :archive
      patch :unarchive
      post :refresh_bookings
    end
    resources :notes, only: %i[create]
    resources :messages, only: %i[create]
    resource :draft, only: %i[update], controller: "drafts"
    post :draft, to: "drafts#update"
  end
  resources :clients, except: %i[destroy] do
    collection do
      get "by-perfectbook/:perfectbook_contact_id", action: :by_perfectbook, as: :by_perfectbook
    end
    member do
      patch :archive
      patch :unarchive
      post :refresh_bookings
    end
    resources :notes, only: %i[create]
    resources :messages, only: %i[create]
    resource :draft, only: %i[update], controller: "drafts"
    post :draft, to: "drafts#update"
  end
  resources :organizations, except: %i[index destroy] do
    resources :notes, only: %i[create]
    resources :messages, only: %i[create]
    resource :draft, only: %i[update], controller: "drafts"
    post :draft, to: "drafts#update"
  end
  resources :messages, only: [] do
    member do
      post :retry
    end
  end
  resources :group_sends, only: %i[create show]
  get "pipeline", to: "pipeline#show"
  patch "pipeline/move", to: "pipeline#move", as: :pipeline_move
  get "document-nudge/:booking_id", to: "templates#document_nudge", as: :document_nudge

  resources :quotes, except: %i[destroy] do
    post :preview, on: :collection, action: :new
    member do
      post :send_quote
      post :duplicate
      post :revise
    end
  end
  # Public tap-to-accept quote page: unguessable token, no sign-in.
  get "q/:token", to: "public_quotes#show", as: :public_quote
  post "q/:token/accept", to: "public_quotes#accept", as: :accept_public_quote
  resources :templates, except: :show do
    collection do
      post :preview, action: :collection_preview
      get :reply_context
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
    post :mailbox_connect, on: :collection
    post :mailbox_test, on: :collection
    post :rotate_site_key, on: :collection
    post :rotate_relay_secret, on: :collection
    delete :signature_logo, to: "settings#remove_signature_logo", on: :collection
    get :logo, to: "settings#logo", on: :collection
    patch :ai, on: :collection
    patch :ad_conversions, on: :collection
    post :rotate_google_feed_password, on: :collection
  end
  get "feeds/google-conversions.csv", to: "google_conversion_feeds#show", as: :google_conversions_feed, format: false
  namespace :ai do
    post "conversations/:conversation_id/draft", to: "drafts#create", as: :conversation_draft
    post "conversations/:conversation_id/summary", to: "summaries#create", as: :conversation_summary
    post "conversations/:conversation_id/suggestion", to: "suggestions#create", as: :conversation_suggestion
    post "conversations/:conversation_id/suggestion/accept", to: "suggestions#accept", as: :accept_conversation_suggestion
    post "conversations/:conversation_id/triage", to: "triages#create", as: :conversation_triage
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
