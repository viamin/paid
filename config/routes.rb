# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users, controllers: { registrations: "users/registrations" }

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check
  get "health/services", to: "health#show"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Dashboard for authenticated users
  get "dashboard", to: "dashboard#show"

  # Integrations hub
  resources :integrations, only: [ :index ]
  resources :integration_credentials, only: [ :index, :new, :create, :show, :destroy ]

  # GitHub tokens management
  resources :github_tokens, only: [ :index, :new, :create, :show, :destroy ] do
    get :repositories, on: :member
    get :validation_status, on: :member
    post :retry_validation, on: :member
  end

  # Linear tokens management
  resources :linear_tokens, only: [ :index, :new, :create, :show, :destroy ]

  # User settings (singleton resource — one per user)
  resource :user_settings, only: [ :edit, :update ]
  resources :providers, except: :show do
    patch :settings, on: :collection
    post :test_agent, on: :member
  end

  # Service container management
  resources :service_containers

  # All agent runs across projects
  resources :agent_runs, only: [ :index ]

  # Prompt management
  resources :prompts do
    get :diff, on: :member
    resources :ab_tests, only: [ :index, :show, :new, :create ] do
      post :start, on: :member
      post :cancel, on: :member
      post :promote, on: :member
    end
  end

  # Style guide management
  resources :style_guides do
    post :compress, on: :member
    post :extract, on: :collection
  end

  # Quality metrics dashboard
  resource :quality_dashboard, only: [ :show ]

  # Projects management
  resources :projects do
    post :toggle_auto_pick, on: :member
    post :toggle_auto_merge, on: :member
    resource :workflow_status, only: [ :show ]
    resource :quality_dashboard, only: [ :show ], controller: "projects/quality_dashboards"
    resource :cost_dashboard, only: [ :show ], controller: "projects/cost_dashboards"
    resources :cost_budgets, only: [ :create, :update, :destroy ], controller: "projects/cost_budgets"
    resources :agent_runs, only: [ :index, :show, :new, :create ], controller: "projects/agent_runs" do
      post :retry, on: :member
      post :refresh_auth, on: :member
      post :quick_create, on: :collection
      post :bump_priority, on: :collection
    end
    resources :project_service_containers, only: [ :create, :destroy ], controller: "projects/service_containers"
    post :detect_services, on: :member
  end

  # API endpoints for agent containers
  namespace :api do
    match "proxy/anthropic/*path", to: "secrets_proxy#anthropic", via: :post, format: false
    match "proxy/openai/*path", to: "secrets_proxy#openai", via: :post, format: false
    match "proxy/google/*path", to: "secrets_proxy#google", via: :post, format: false
    match "proxy/github/*path", to: "github_proxy#proxy", via: [ :get, :post, :patch ], format: false
    get "proxy/git-credentials", to: "git_credentials#show"

    get "knowledge/search", to: "knowledge_search#search"

    # GitHub webhook receiver for PR review events
    post "github_webhooks", to: "github_webhooks#create"
  end

  # Defines the root path route ("/")
  root "dashboard#show"
end
