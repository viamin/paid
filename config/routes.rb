# frozen_string_literal: true

Rails.application.routes.draw do
  mount RailsPerformance::Engine, at: "rails/performance" if defined?(RailsPerformance)
  mount Dial::Engine, at: "dial" if defined?(Dial::Engine)

  devise_for :users, controllers: { registrations: "users/registrations" }

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check
  get "health/services", to: "health#show"
  get "health/liveness", to: "health#liveness"
  get "health/readiness", to: "health#readiness"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Notifications
  resources :notifications, only: [ :index ] do
    patch :read, on: :member
    patch :dismiss, on: :member
    post :mark_all_read, on: :collection
  end
  resources :remediation_decisions, only: [ :show ] do
    post :revert, on: :member
  end

  # Onboarding wizard
  resource :onboarding, only: [ :show, :update ], controller: "onboarding" do
    post :skip
  end

  # Dashboard for authenticated users
  get "dashboard", to: "dashboard#show"
  get "dashboard/live", to: redirect("/dashboard")
  get "dashboard/metrics", to: "dashboard#metrics", as: :dashboard_metrics
  get "dashboard/performance", to: "dashboard#performance", as: :dashboard_performance
  get "dashboard/decision_metrics", to: "dashboard#decision_metrics", as: :dashboard_decision_metrics
  get "dashboard/runner_health", to: "dashboard#runner_health", as: :dashboard_runner_health
  get "dashboard/queue_health", to: "dashboard#queue_health", as: :dashboard_queue_health
  get "dashboard/knowledge_stats", to: "dashboard#knowledge_stats", as: :dashboard_knowledge_stats
  get "dashboard/pr_cycle_time", to: "dashboard#pr_cycle_time", as: :dashboard_pr_cycle_time
  post "dashboard/cancel_run/:id", to: "dashboard#cancel_run", as: :dashboard_cancel_run

  # Integrations hub
  resources :integrations, only: [ :index, :new ]
  resources :integration_credentials, only: [ :index, :new, :create, :show, :destroy ]

  # GitHub tokens management
  resources :github_tokens, only: [ :index, :new, :create, :show, :destroy ] do
    get :repositories, on: :member
    get :validation_status, on: :member
    post :retry_validation, on: :member
  end

  resources :github_installations, only: [ :index, :show ] do
    get :repositories, on: :member
    get :migrate, on: :member, as: :migrate_project, action: :migrate_projects
    post :migrate, on: :member, action: :migrate_from_token
    post :check_access, on: :member
  end

  # Linear tokens management
  resources :linear_tokens, only: [ :index, :new, :create, :show, :destroy ]

  # Issue tracker configurations (account/user/project-level)
  resources :tracker_configurations, only: [ :index, :show, :create, :update, :destroy ]

  # LLM provider API keys
  resources :provider_api_keys, only: [ :index, :new, :create, :show, :edit, :update, :destroy ]

  # User settings (singleton resource — one per user)
  resource :user_settings, only: [ :edit, :update ]

  # Customer-facing account administration
  resource :account, only: [ :show, :update ]
  resource :account_roi_dashboard, only: [ :show ], controller: "accounts/roi_dashboards" do
    get :export
  end
  resource :account_compliance_dashboard, only: [ :show, :update ], controller: "accounts/compliance_dashboards" do
    get :export
  end
  resource :account_operations_dashboard, only: [ :show, :update ], controller: "accounts/operations_dashboards" do
    get :export
  end
  resources :account_memberships, only: [ :create, :update, :destroy ]
  resource :account_ownership_transfer, only: [ :create ]
  resource :account_lifecycle, only: [ :update ]

  # Account audit log
  resources :account_audit_logs, only: [ :index ] do
    get :export, on: :collection
  end

  # Account tenant configuration
  resource :tenant_configuration, only: [ :edit, :update ]

  # Account-level pre-commit requirements (defaults inherited by all projects)
  resources :account_pre_commit_requirements, only: [ :index, :show, :create, :update, :destroy ]

  # User-level pre-commit requirements (per-user overrides)
  resources :user_pre_commit_requirements, only: [ :index, :show, :create, :update, :destroy ]

  # Account-level PR templates (defaults inherited by all projects)
  resources :account_pr_templates, only: [ :index, :show, :create, :update, :destroy ]

  # User-level PR templates (per-user overrides)
  resources :user_pr_templates, only: [ :index, :show, :create, :update, :destroy ]
  resources :runners, except: :show do
    patch :settings, on: :collection
    post :test_agent, on: :member
  end
  resources :free_models, only: :index, controller: "free_models" do
    patch :project_preferences, on: :collection
  end

  # Service container management
  resources :service_containers
  # MCP server definitions management
  resources :mcp_server_definitions
  resources :marketplace_entries
  resource :marketplace_entry_pdf_import, only: [ :new, :create ], controller: "marketplace_entry_pdf_imports"

  # All agent runs across projects
  resources :agent_runs, only: [ :index ] do
    collection do
      post :pause_scheduler
      post :resume_scheduler
    end
  end

  # Exception incidents (captured by the exception-handling pipeline)
  resources :exception_incidents, only: [ :index ]

  # Prompt management
  resources :prompts do
    get :diff, on: :member
    resources :ab_tests, only: [ :index, :show, :new, :create ] do
      post :start, on: :member
      post :cancel, on: :member
      post :promote, on: :member
    end
    resources :reviews, only: [ :index, :show, :update ], controller: "prompt_reviews" do
      post :approve, on: :member
      post :reject, on: :member
    end
  end

  # Account-wide pending prompt review queue
  get "prompt_reviews", to: "prompt_reviews#queue", as: :prompt_reviews_queue

  resources :strategies, only: [] do
    resources :reviews, only: [ :index, :show, :update ], controller: "strategy_reviews" do
      post :approve, on: :member
      post :reject, on: :member
    end
  end

  get "strategy_reviews", to: "strategy_reviews#queue", as: :strategy_reviews_queue

  # Plan review management for pending feature decomposition plans
  resources :plan_reviews, only: [ :index ] do
    post :approve, on: :member
    post :reject, on: :member
    post :revise, on: :member
  end

  # Style guide management
  resources :style_guides do
    post :compress, on: :member
    post :extract, on: :collection
  end

  # Quality metrics dashboard
  resource :quality_dashboard, only: [ :show ]

  # Knowledge search and artifacts
  get "knowledge/search", to: "knowledge/search#index", as: :knowledge_search
  get "knowledge/search/results", to: "knowledge/search#search", as: :knowledge_search_results
  resources :knowledge_artifacts, only: [ :show ], controller: "knowledge/artifacts", as: :knowledge_artifacts

  # Projects management
  resources :projects do
    post :toggle_auto_pick, on: :member
    post :toggle_auto_merge, on: :member
    post :toggle_pause, on: :member
    post :quality_resume, on: :member
    post :cleanup_stale_runs, on: :member
    post :detect_screenshot_settings, on: :member
    post :commit_screenshot_config, on: :member
    resource :workflow_status, only: [ :show ] do
      post :restart
    end
    resource :quality_dashboard, only: [ :show ], controller: "projects/quality_dashboards" do
      get :export
    end
    resource :bundle_performance_dashboard, only: [ :show ], controller: "projects/bundle_performance_dashboards"
    resource :roi_dashboard, only: [ :show ], controller: "projects/roi_dashboards" do
      get :export
    end
    resource :quality_thresholds, only: [ :update ], controller: "projects/quality_thresholds"
    resource :cost_snapshot, only: [ :show ], controller: "projects/cost_snapshots"
    resource :cost_dashboard, only: [ :show ], controller: "projects/cost_dashboards"
    resource :interop_settings, only: [ :update ], controller: "projects/interop_settings"
    resources :roi_benchmarks, only: [ :create, :destroy ], controller: "projects/roi_benchmarks"
    resource :screenshot_config, only: [], controller: "projects/screenshot_configs" do
      post :detect
    end
    resources :cost_budgets, only: [ :create, :update, :destroy ], controller: "projects/cost_budgets"
    resources :interoperability_imports, only: [ :create ], controller: "projects/interoperability_imports"
    resources :connector_events, only: [ :index ], controller: "projects/connector_events"
    resources :agent_runs, only: [ :index, :show, :new, :create ], controller: "projects/agent_runs" do
      post :cancel, on: :member
      post :retry, on: :member
      post :refresh_auth, on: :member
      post :diagnose_error, on: :member
      post :resume, on: :member
      post :terminate, on: :member
      get :provenance, on: :member
      post :quick_create, on: :collection
      post :bump_priority, on: :collection
      post :toggle_auto_continue_pause, on: :collection
    end
    resources :pre_commit_requirements, only: [ :index, :show, :create, :update, :destroy ],
      controller: "projects/pre_commit_requirements"
    resources :pr_templates, only: [ :index, :show, :create, :update, :destroy ],
      controller: "projects/pr_templates"
    resources :project_service_containers, only: [ :create, :destroy ], controller: "projects/service_containers"
    resources :project_mcp_servers, only: [ :create, :destroy ], controller: "projects/mcp_servers"
    resources :issues, only: [] do
      resource :merge_subscription, only: [ :show, :create, :destroy ],
        controller: "projects/issue_merge_subscriptions"
      resource :clarifying_questions, only: [ :show, :create ],
        controller: "projects/clarifying_questions"
    end
    post :detect_services, on: :member
    resource :context_intake, only: [ :show, :create, :update ],
      controller: "knowledge/context_intake" do
      post :complete
    end
    resource :pdf_knowledge_import, only: [ :new, :create ], controller: "projects/pdf_knowledge_imports"
    post :ensure_labels, on: :member

    resources :knowledge_recommendations, only: [ :index, :update ],
      controller: "projects/knowledge_recommendations"

    resources :convention_settings, only: [ :index ], controller: "projects/convention_settings" do
      post :update_override, on: :collection
      patch :update_recommendation, on: :collection
    end

    # Project-scoped knowledge browsing and search
    namespace :knowledge do
      resources :browse, only: [ :index, :show ]
      get "search", to: "search#project_search", as: :search
      get "search/results", to: "search#project_search_results", as: :search_results
    end
  end

  # API endpoints for agent containers
  namespace :api do
    resources :projects, only: [] do
      resources :external_agent_runs, only: [ :create ], controller: "projects/external_agent_runs"
      resources :connector_events, only: [ :create ], controller: "projects/connector_events"
    end

    get "metrics", to: "metrics#show"
    match "proxy/anthropic/*path", to: "secrets_proxy#anthropic", via: :post, format: false
    match "proxy/openai/*path", to: "secrets_proxy#openai", via: [ :get, :post ], format: false
    match "proxy/google/*path", to: "secrets_proxy#google", via: :post, format: false
    match "proxy/github/*path", to: "github_proxy#proxy", via: [ :get, :post, :patch ], format: false
    get "proxy/knowledge/search", to: "proxy/knowledge_search#search"
    get "proxy/git-credentials", to: "git_credentials#show"

    get "knowledge/search", to: "knowledge_search#search"
    get "knowledge/audit", to: "knowledge_audit#index"
    resources :marketplace_entries, only: [ :index, :show ]

    # GitHub webhook receiver for PR reviews, merges, and comments
    post "github_webhooks", to: "github_webhooks#create"

    # MCP server endpoint for chat agent tool use
    scope :mcp do
      get "sse", to: "mcp#sse", as: :mcp_sse
      post "call", to: "mcp#call", as: :mcp_call
    end

    # Billing API for external billing system integration
    get "billing/usage", to: "billing#usage"
    get "billing/plan", to: "billing#plan"
    get "billing/periods", to: "billing#periods"
    get "billing/periods/:id", to: "billing#show_period", as: :billing_period
    get "billing/invoices", to: "billing#invoices"
    get "billing/invoices/:id", to: "billing#show_invoice", as: :billing_invoice
  end

  # Chat sessions and messages
  resources :chat_sessions, path: "chat", only: %i[index create show update destroy] do
    patch :archive, on: :member
    collection do
      get :sidebar_page
    end
    member do
      get :older_messages
    end
    resources :chat_messages, path: "messages", only: %i[index create]
  end

  authenticate :user, ->(user) { user.operator? } do
    mount_avo at: "/admin"
  end

  match "/admin(/*path)", to: "operator_console_access#show", via: :all

  # Defines the root path route ("/")
  root "dashboard#show"
end
