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

  # GitHub tokens management
  resources :github_tokens, only: [ :index, :new, :create, :show, :destroy ] do
    get :repositories, on: :member
    get :validation_status, on: :member
    post :retry_validation, on: :member
  end

  # User settings (singleton resource — one per user)
  resource :user_settings, only: [ :edit, :update ]
  resources :providers, except: :show do
    patch :settings, on: :collection
  end

  # Service container management
  resources :service_containers

  # All agent runs across projects
  resources :agent_runs, only: [ :index ]

  # Prompt management
  resources :prompts do
    get :diff, on: :member
  end

  # Style guide management
  resources :style_guides do
    post :compress, on: :member
  end

  # Projects management
  resources :projects do
    post :toggle_auto_pick, on: :member
    resource :workflow_status, only: [ :show ]
    resource :quality_dashboard, only: [ :show ], controller: "projects/quality_dashboards"
    resources :agent_runs, only: [ :index, :show, :new, :create ], controller: "projects/agent_runs" do
      post :retry, on: :member
      post :refresh_auth, on: :member
      post :quick_create, on: :collection
    end
    resources :project_service_containers, only: [ :create, :destroy ], controller: "projects/service_containers"
    post :detect_services, on: :member
  end

  # API endpoints for agent containers
  namespace :api do
    match "proxy/anthropic/*path", to: "secrets_proxy#anthropic", via: :post
    match "proxy/openai/*path", to: "secrets_proxy#openai", via: :post
    match "proxy/github/*path", to: "github_proxy#proxy", via: [ :get, :post, :patch ]
    get "proxy/git-credentials", to: "git_credentials#show"
  end

  # Defines the root path route ("/")
  root "dashboard#show"
end
