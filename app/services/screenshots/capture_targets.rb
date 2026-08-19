# frozen_string_literal: true

module Screenshots
  class CaptureTargets
    UnmappedUiChangeError = Class.new(StandardError)

    Target = Struct.new(:slug, :path_builder, :requires_auth, keyword_init: true) do
      def path(seed_data)
        resolved_seed_data = if seed_data.is_a?(Hash)
          seed_data.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        else
          seed_data
        end

        path_builder.respond_to?(:call) ? path_builder.call(resolved_seed_data) : path_builder
      end
    end

    SHARED_TARGET_KEYS = %i[
      sign_in
      dashboard
      projects
      project_show
      agent_runs
      prompts
      providers
      integrations
      notifications
      exception_incidents
      service_containers
      docker_hosts
      mcp_server_definitions
      onboarding
      user_settings
      account
      account_roi_dashboard
      account_operations_dashboard
      account_audit_logs
      remediation_decision_show
      quality_dashboard
      chat_sessions
      ab_tests
      style_guides
      knowledge_search
      project_convention_settings
    ].freeze

    AUTHENTICATED_SHARED_TARGET_KEYS = (SHARED_TARGET_KEYS - [ :sign_in ]).freeze

    HELPER_TARGETS = {
      "application" => SHARED_TARGET_KEYS,
      "cost_dashboard" => %i[project_cost_dashboard project_cost_snapshot],
      "health_check" => [ :project_health_check ],
      "integrations" => %i[integrations integrations_new],
      "knowledge" => %i[knowledge_search project_knowledge_search project_knowledge_browse project_context_intake project_knowledge_recommendations],
      "quality_metrics" => %i[quality_dashboard project_quality_dashboard],
      "roi_dashboard" => %i[account_roi_dashboard project_roi_dashboard],
      "workflow" => [ :workflow_status ]
    }.freeze

    TARGETS = {
      sign_in: Target.new(slug: "sign_in", path_builder: "/users/sign_in", requires_auth: false),
      sign_up: Target.new(slug: "sign_up", path_builder: "/users/sign_up", requires_auth: false),
      forgot_password: Target.new(slug: "forgot_password", path_builder: "/users/password/new", requires_auth: false),
      confirmation: Target.new(slug: "confirmation", path_builder: "/users/confirmation/new", requires_auth: false),
      unlock: Target.new(slug: "unlock", path_builder: "/users/unlock/new", requires_auth: false),
      dashboard: Target.new(slug: "dashboard", path_builder: "/dashboard", requires_auth: true),
      notifications: Target.new(slug: "notifications", path_builder: "/notifications", requires_auth: true),
      exception_incidents: Target.new(slug: "exception_incidents", path_builder: "/exception_incidents", requires_auth: true),
      onboarding: Target.new(slug: "onboarding", path_builder: "/onboarding", requires_auth: true),
      integrations: Target.new(slug: "integrations", path_builder: "/integrations", requires_auth: true),
      integrations_new: Target.new(slug: "integrations_new", path_builder: "/integrations/new", requires_auth: true),
      admin_github_app_setup: Target.new(slug: "admin_github_app_setup", path_builder: "/admin/github_app/setup", requires_auth: true),
      free_models_catalog: Target.new(slug: "free_models_catalog", path_builder: "/free_models", requires_auth: true),
      integration_credentials: Target.new(slug: "integration_credentials", path_builder: "/integration_credentials", requires_auth: true),
      integration_credential_new: Target.new(slug: "integration_credential_new", path_builder: "/integration_credentials/new", requires_auth: true),
      integration_credential_show: Target.new(slug: "integration_credential_show", path_builder: ->(seed_data) { "/integration_credentials/#{seed_data.fetch(:integration_credential).id}" }, requires_auth: true),
      runner_credentials: Target.new(
        slug: "runner_credentials",
        path_builder: ->(seed_data) { "/runners/#{seed_data.fetch(:runner).id}/runner_credentials" },
        requires_auth: true
      ),
      runner_credential_new: Target.new(
        slug: "runner_credential_new",
        path_builder: ->(seed_data) { "/runners/#{seed_data.fetch(:runner).id}/runner_credentials/new" },
        requires_auth: true
      ),
      runner_credential_show: Target.new(
        slug: "runner_credential_show",
        path_builder: ->(seed_data) { "/runners/#{seed_data.fetch(:runner).id}/runner_credentials/#{seed_data.fetch(:runner_credential).id}" },
        requires_auth: true
      ),
      claude_login_session_new: Target.new(slug: "claude_login_session_new", path_builder: "/claude_login_sessions/new", requires_auth: true),
      claude_login_session_show: Target.new(slug: "claude_login_session_show", path_builder: ->(seed_data) { "/claude_login_sessions/#{seed_data.fetch(:claude_login_session).external_id}" }, requires_auth: true),
      codex_login_session_new: Target.new(slug: "codex_login_session_new", path_builder: "/codex_login_sessions/new", requires_auth: true),
      codex_login_session_show: Target.new(slug: "codex_login_session_show", path_builder: ->(seed_data) { "/codex_login_sessions/#{seed_data.fetch(:codex_login_session).external_id}" }, requires_auth: true),
      github_installations: Target.new(slug: "github_installations", path_builder: "/github_installations", requires_auth: true),
      github_installation_show: Target.new(slug: "github_installation_show", path_builder: ->(seed_data) { "/github_installations/#{seed_data.fetch(:github_installation).id}" }, requires_auth: true),
      github_installation_migrate_projects: Target.new(
        slug: "github_installation_migrate_projects",
        path_builder: ->(seed_data) { "/github_installations/#{seed_data.fetch(:github_installation).id}/migrate" },
        requires_auth: true
      ),
      github_tokens: Target.new(slug: "github_tokens", path_builder: "/github_tokens", requires_auth: true),
      github_token_new: Target.new(slug: "github_token_new", path_builder: "/github_tokens/new", requires_auth: true),
      github_token_show: Target.new(slug: "github_token_show", path_builder: ->(seed_data) { "/github_tokens/#{seed_data.fetch(:github_token).id}" }, requires_auth: true),
      linear_tokens: Target.new(slug: "linear_tokens", path_builder: "/linear_tokens", requires_auth: true),
      linear_token_new: Target.new(slug: "linear_token_new", path_builder: "/linear_tokens/new", requires_auth: true),
      linear_token_show: Target.new(slug: "linear_token_show", path_builder: ->(seed_data) { "/linear_tokens/#{seed_data.fetch(:linear_token).id}" }, requires_auth: true),
      provider_api_keys: Target.new(slug: "provider_api_keys", path_builder: "/provider_api_keys", requires_auth: true),
      provider_api_key_new: Target.new(slug: "provider_api_key_new", path_builder: "/provider_api_keys/new", requires_auth: true),
      provider_api_key_show: Target.new(slug: "provider_api_key_show", path_builder: ->(seed_data) { "/provider_api_keys/#{seed_data.fetch(:provider_api_key).id}" }, requires_auth: true),
      provider_api_key_edit: Target.new(slug: "provider_api_key_edit", path_builder: ->(seed_data) { "/provider_api_keys/#{seed_data.fetch(:provider_api_key).id}/edit" }, requires_auth: true),
      user_settings: Target.new(slug: "user_settings", path_builder: "/user_settings/edit", requires_auth: true),
      account: Target.new(slug: "account", path_builder: "/account", requires_auth: true),
      account_roi_dashboard: Target.new(slug: "account_roi_dashboard", path_builder: "/account_roi_dashboard", requires_auth: true),
      account_operations_dashboard: Target.new(slug: "account_operations_dashboard", path_builder: "/account_operations_dashboard", requires_auth: true),
      account_compliance_dashboard: Target.new(slug: "account_compliance_dashboard", path_builder: "/account_compliance_dashboard", requires_auth: true),
      account_audit_logs: Target.new(slug: "account_audit_logs", path_builder: "/account_audit_logs", requires_auth: true),
      account_egress_allowlist: Target.new(slug: "account_egress_allowlist", path_builder: "/account_egress_allowlist_entries", requires_auth: true),
      project_egress_allowlist: Target.new(
        slug: "project_egress_allowlist",
        path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/egress_allowlist_entries" },
        requires_auth: true
      ),
      remediation_decision_show: Target.new(
        slug: "remediation_decision_show",
        path_builder: ->(seed_data) { "/remediation_decisions/#{seed_data.fetch(:remediation_decision).id}" },
        requires_auth: true
      ),
      tenant_configuration: Target.new(slug: "tenant_configuration", path_builder: "/tenant_configuration/edit", requires_auth: true),
      providers: Target.new(slug: "providers", path_builder: "/runners", requires_auth: true),
      providers_new: Target.new(slug: "providers_new", path_builder: "/runners/new?form_variant=subscription", requires_auth: true),
      providers_edit: Target.new(slug: "providers_edit", path_builder: ->(seed_data) { "/runners/#{seed_data.fetch(:runner).id}/edit" }, requires_auth: true),
      marketplace_entries: Target.new(slug: "marketplace_entries", path_builder: "/marketplace_entries", requires_auth: true),
      marketplace_entry_new: Target.new(slug: "marketplace_entry_new", path_builder: "/marketplace_entries/new", requires_auth: true),
      marketplace_entry_show: Target.new(slug: "marketplace_entry_show", path_builder: ->(seed_data) { "/marketplace_entries/#{seed_data.fetch(:marketplace_entry).id}" }, requires_auth: true),
      marketplace_entry_edit: Target.new(slug: "marketplace_entry_edit", path_builder: ->(seed_data) { "/marketplace_entries/#{seed_data.fetch(:marketplace_entry).id}/edit" }, requires_auth: true),
      marketplace_entry_pdf_import_new: Target.new(slug: "marketplace_entry_pdf_import_new", path_builder: "/marketplace_entry_pdf_import/new", requires_auth: true),
      service_containers: Target.new(slug: "service_containers", path_builder: "/service_containers", requires_auth: true),
      service_container_new: Target.new(slug: "service_container_new", path_builder: "/service_containers/new", requires_auth: true),
      service_container_show: Target.new(slug: "service_container_show", path_builder: ->(seed_data) { "/service_containers/#{seed_data.fetch(:service_container).id}" }, requires_auth: true),
      service_container_edit: Target.new(slug: "service_container_edit", path_builder: ->(seed_data) { "/service_containers/#{seed_data.fetch(:service_container).id}/edit" }, requires_auth: true),
      docker_hosts: Target.new(slug: "docker_hosts", path_builder: "/docker_hosts", requires_auth: true),
      docker_host_show: Target.new(slug: "docker_host_show", path_builder: ->(seed_data) { "/docker_hosts/#{seed_data.fetch(:docker_host).id}" }, requires_auth: true),
      docker_host_edit: Target.new(slug: "docker_host_edit", path_builder: ->(seed_data) { "/docker_hosts/#{seed_data.fetch(:docker_host).id}/edit" }, requires_auth: true),
      mcp_server_definitions: Target.new(slug: "mcp_server_definitions", path_builder: "/mcp_server_definitions", requires_auth: true),
      mcp_server_definition_new: Target.new(slug: "mcp_server_definition_new", path_builder: "/mcp_server_definitions/new", requires_auth: true),
      mcp_server_definition_show: Target.new(slug: "mcp_server_definition_show", path_builder: ->(seed_data) { "/mcp_server_definitions/#{seed_data.fetch(:mcp_server_definition).id}" }, requires_auth: true),
      mcp_server_definition_edit: Target.new(slug: "mcp_server_definition_edit", path_builder: ->(seed_data) { "/mcp_server_definitions/#{seed_data.fetch(:mcp_server_definition).id}/edit" }, requires_auth: true),
      agent_runs: Target.new(slug: "agent_runs", path_builder: "/agent_runs", requires_auth: true),
      prompts: Target.new(slug: "prompts", path_builder: "/prompts", requires_auth: true),
      prompt_new: Target.new(slug: "prompt_new", path_builder: "/prompts/new", requires_auth: true),
      prompt_show: Target.new(slug: "prompt_show", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}" }, requires_auth: true),
      prompt_edit: Target.new(slug: "prompt_edit", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/edit" }, requires_auth: true),
      prompt_diff: Target.new(slug: "prompt_diff", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/diff" }, requires_auth: true),
      prompt_reviews_queue: Target.new(slug: "prompt_reviews_queue", path_builder: "/prompt_reviews", requires_auth: true),
      prompt_reviews: Target.new(slug: "prompt_reviews", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/reviews" }, requires_auth: true),
      prompt_review_show: Target.new(slug: "prompt_review_show", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/reviews/#{seed_data.fetch(:pending_prompt_version).id}" }, requires_auth: true),
      plan_reviews: Target.new(slug: "plan_reviews", path_builder: "/plan_reviews", requires_auth: true),
      strategy_reviews_queue: Target.new(slug: "strategy_reviews_queue", path_builder: "/strategy_reviews", requires_auth: true),
      strategy_reviews: Target.new(slug: "strategy_reviews", path_builder: ->(seed_data) { "/strategies/#{seed_data.fetch(:strategy).id}/reviews" }, requires_auth: true),
      strategy_review_show: Target.new(slug: "strategy_review_show", path_builder: ->(seed_data) { "/strategies/#{seed_data.fetch(:strategy).id}/reviews/#{seed_data.fetch(:pending_strategy_version).id}" }, requires_auth: true),
      ab_tests: Target.new(slug: "ab_tests", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/ab_tests" }, requires_auth: true),
      ab_test_new: Target.new(slug: "ab_test_new", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/ab_tests/new" }, requires_auth: true),
      ab_test_show: Target.new(slug: "ab_test_show", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/ab_tests/#{seed_data.fetch(:ab_test).id}" }, requires_auth: true),
      style_guides: Target.new(slug: "style_guides", path_builder: "/style_guides", requires_auth: true),
      style_guide_new: Target.new(slug: "style_guide_new", path_builder: "/style_guides/new", requires_auth: true),
      style_guide_show: Target.new(slug: "style_guide_show", path_builder: ->(seed_data) { "/style_guides/#{seed_data.fetch(:style_guide).id}" }, requires_auth: true),
      style_guide_edit: Target.new(slug: "style_guide_edit", path_builder: ->(seed_data) { "/style_guides/#{seed_data.fetch(:style_guide).id}/edit" }, requires_auth: true),
      chat_sessions: Target.new(slug: "chat_sessions", path_builder: "/chat", requires_auth: true),
      chat_session_show: Target.new(slug: "chat_session_show", path_builder: ->(seed_data) { "/chat/#{seed_data.fetch(:chat_session).id}" }, requires_auth: true),
      quality_dashboard: Target.new(slug: "quality_dashboard", path_builder: "/quality_dashboard", requires_auth: true),
      knowledge_search: Target.new(slug: "knowledge_search", path_builder: "/knowledge/search", requires_auth: true),
      public_icon_png: Target.new(slug: "public_icon_png", path_builder: "/icon.png", requires_auth: false),
      public_icon_svg: Target.new(slug: "public_icon_svg", path_builder: "/icon.svg", requires_auth: false),
      public_400: Target.new(slug: "public_400", path_builder: "/400.html", requires_auth: false),
      public_404: Target.new(slug: "public_404", path_builder: "/404.html", requires_auth: false),
      public_406_unsupported_browser: Target.new(slug: "public_406_unsupported_browser", path_builder: "/406-unsupported-browser.html", requires_auth: false),
      public_422: Target.new(slug: "public_422", path_builder: "/422.html", requires_auth: false),
      public_500: Target.new(slug: "public_500", path_builder: "/500.html", requires_auth: false),
      projects: Target.new(slug: "projects", path_builder: "/projects", requires_auth: true),
      project_new: Target.new(slug: "project_new", path_builder: "/projects/new", requires_auth: true),
      project_show: Target.new(slug: "project_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}" }, requires_auth: true),
      preview_session_show: Target.new(
        slug: "preview_session_show",
        path_builder: ->(seed_data) { "/previews/#{seed_data.fetch(:preview_session).id}" },
        requires_auth: true
      ),
      project_issue_clarifying_questions: Target.new(
        slug: "project_issue_clarifying_questions",
        path_builder: ->(seed_data) {
          "/projects/#{seed_data.fetch(:project).id}/issues/#{seed_data.fetch(:clarifying_issue).id}/clarifying_questions"
        },
        requires_auth: true
      ),
      project_edit: Target.new(slug: "project_edit", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/edit" }, requires_auth: true),
      project_health_check: Target.new(slug: "project_health_check", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/health" }, requires_auth: true),
      project_agent_runs: Target.new(slug: "project_agent_runs", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs" }, requires_auth: true),
      project_agent_run_new: Target.new(slug: "project_agent_run_new", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs/new" }, requires_auth: true),
      project_agent_run_show: Target.new(slug: "project_agent_run_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs/#{seed_data.fetch(:agent_run).id}" }, requires_auth: true),
      project_agent_run_provenance: Target.new(
        slug: "project_agent_run_provenance",
        path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs/#{seed_data.fetch(:agent_run).id}/provenance" },
        requires_auth: true
      ),
      project_quality_dashboard: Target.new(slug: "project_quality_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/quality_dashboard" }, requires_auth: true),
      project_scaling_dashboard: Target.new(slug: "project_scaling_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/scaling_dashboard" }, requires_auth: true),
      project_roi_dashboard: Target.new(slug: "project_roi_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/roi_dashboard" }, requires_auth: true),
      project_convention_settings: Target.new(slug: "project_convention_settings", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/convention_settings" }, requires_auth: true),
      project_bundle_performance_dashboard: Target.new(slug: "project_bundle_performance_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/bundle_performance_dashboard" }, requires_auth: true),
      project_cost_snapshot: Target.new(slug: "project_cost_snapshot", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/cost_snapshot" }, requires_auth: true),
      project_cost_dashboard: Target.new(slug: "project_cost_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/cost_dashboard" }, requires_auth: true),
      project_context_intake: Target.new(slug: "project_context_intake", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/context_intake" }, requires_auth: true),
      project_pdf_knowledge_import_new: Target.new(slug: "project_pdf_knowledge_import_new", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/pdf_knowledge_import/new" }, requires_auth: true),
      project_knowledge_search: Target.new(slug: "project_knowledge_search", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/knowledge/search" }, requires_auth: true),
      project_knowledge_browse: Target.new(slug: "project_knowledge_browse", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/knowledge/browse" }, requires_auth: true),
      project_knowledge_browse_show: Target.new(slug: "project_knowledge_browse_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/knowledge/browse/route" }, requires_auth: true),
      project_knowledge_artifact_show: Target.new(slug: "project_knowledge_artifact_show", path_builder: ->(seed_data) { "/knowledge_artifacts/#{seed_data.fetch(:knowledge_artifact).id}" }, requires_auth: true),
      project_knowledge_recommendations: Target.new(slug: "project_knowledge_recommendations", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/knowledge_recommendations" }, requires_auth: true),
      project_change_intent_show: Target.new(
        slug: "project_change_intent_show",
        path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/change_intents/#{seed_data.fetch(:change_intent).id}" },
        requires_auth: true
      ),
      workflow_status: Target.new(slug: "workflow_status", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/workflow_status" }, requires_auth: true)
    }.freeze

    def self.call(changed_files:, repo_path: nil)
      new(changed_files: changed_files, repo_path: repo_path).call
    end

    def initialize(changed_files:, repo_path: nil)
      @changed_files = Array(changed_files)
      @repo_path = repo_path.presence&.chomp("/")
    end

    def call
      return materialize(SHARED_TARGET_KEYS) if @changed_files.empty?

      mapping = @changed_files.each_with_object({}) { |path, h| h[path] = targets_for(path) }
      target_keys = mapping.values.flatten.uniq
      unresolved_files = mapping.select { |_, targets| targets.empty? }.keys

      if unresolved_files.any?
        raise UnmappedUiChangeError,
          "No screenshot targets are defined for: #{unresolved_files.join(', ')}. " \
          "Add a Screenshots::CaptureTargets mapping before merging UI changes for those files."
      end

      materialize(target_keys)
    end

    private

    def materialize(target_keys)
      target_keys.map { |key| TARGETS.fetch(key) }
    end

    # Maps a controller file path to the target keys whose pages that controller serves.
    CONTROLLER_TARGETS = {
      "dashboard_controller.rb" => [ :dashboard ],
      "home_controller.rb" => [ :dashboard ],
      "projects_controller.rb" => %i[projects project_new project_show project_edit],
      "previews_controller.rb" => [ :preview_session_show ],
      "agent_runs_controller.rb" => [ :agent_runs ],
      "prompts_controller.rb" => %i[prompts prompt_new prompt_show prompt_edit prompt_diff],
      "prompt_reviews_controller.rb" => %i[prompt_reviews_queue prompt_reviews prompt_review_show],
      "plan_reviews_controller.rb" => [ :plan_reviews ],
      "strategy_reviews_controller.rb" => %i[strategy_reviews_queue strategy_reviews strategy_review_show],
      "ab_tests_controller.rb" => %i[ab_tests ab_test_new ab_test_show],
      "providers_controller.rb" => %i[providers providers_new providers_edit],
      "runners_controller.rb" => %i[providers providers_new providers_edit],
      "runner_credentials_controller.rb" => %i[runner_credentials runner_credential_new runner_credential_show],
      "provider_api_keys_controller.rb" => %i[provider_api_keys provider_api_key_new provider_api_key_show provider_api_key_edit],
      "marketplace_entries_controller.rb" => %i[marketplace_entries marketplace_entry_new marketplace_entry_show marketplace_entry_edit],
      "integrations_controller.rb" => %i[integrations integrations_new],
      "free_models_controller.rb" => [ :free_models_catalog ],
      "integration_credentials_controller.rb" => %i[integration_credentials integration_credential_new integration_credential_show],
      "claude_login_sessions_controller.rb" => %i[claude_login_session_new claude_login_session_show],
      "codex_login_sessions_controller.rb" => %i[codex_login_session_new codex_login_session_show],
      "github_installations_controller.rb" => %i[
        github_installations
        github_installation_show
        github_installation_migrate_projects
      ],
      "github_tokens_controller.rb" => %i[github_tokens github_token_new github_token_show],
      "linear_tokens_controller.rb" => %i[linear_tokens linear_token_new linear_token_show],
      "notifications_controller.rb" => [ :notifications ],
      "exception_incidents_controller.rb" => [ :exception_incidents ],
      "onboarding_controller.rb" => [ :onboarding ],
      "user_settings_controller.rb" => [ :user_settings ],
      "accounts_controller.rb" => [ :account ],
      "account_audit_logs_controller.rb" => [ :account_audit_logs ],
      "remediation_decisions_controller.rb" => [ :remediation_decision_show ],
      "account_memberships_controller.rb" => [ :account ],
      "account_ownership_transfers_controller.rb" => [ :account ],
      "account_lifecycles_controller.rb" => [ :account ],
      "tenant_configurations_controller.rb" => [ :tenant_configuration ],
      "service_containers_controller.rb" => %i[service_containers service_container_new service_container_show service_container_edit],
      "docker_hosts_controller.rb" => %i[docker_hosts docker_host_show docker_host_edit],
      "account_docker_host_preferences_controller.rb" => [ :docker_hosts ],
      "mcp_server_definitions_controller.rb" => %i[mcp_server_definitions mcp_server_definition_new mcp_server_definition_show mcp_server_definition_edit],
      "style_guides_controller.rb" => %i[style_guides style_guide_new style_guide_show style_guide_edit],
      "chat_sessions_controller.rb" => %i[chat_sessions chat_session_show],
      "chat_messages_controller.rb" => [ :chat_session_show ],
      "quality_dashboards_controller.rb" => [ :quality_dashboard ],
      "workflow_statuses_controller.rb" => [ :workflow_status ],
      "tracker_configurations_controller.rb" => [ :project_edit ],
      "account_pr_templates_controller.rb" => [ :project_edit ],
      "account_pre_commit_requirements_controller.rb" => [ :project_edit ],
      "user_pr_templates_controller.rb" => [ :user_settings ],
      "user_pre_commit_requirements_controller.rb" => [ :user_settings ],
      "application_controller.rb" => AUTHENTICATED_SHARED_TARGET_KEYS
    }.freeze

    # Nested controller path => target keys
    NESTED_CONTROLLER_TARGETS = {
      "users/registrations_controller.rb" => [ :sign_up ],
      "accounts/compliance_dashboards_controller.rb" => [ :account_compliance_dashboard ],
      "accounts/operations_dashboards_controller.rb" => [ :account_operations_dashboard ],
      "accounts/roi_dashboards_controller.rb" => [ :account_roi_dashboard ],
      "accounts/egress_allowlist_entries_controller.rb" => [ :account_egress_allowlist ],
      "projects/egress_allowlist_entries_controller.rb" => [ :project_egress_allowlist ],
      "projects/agent_runs_controller.rb" => %i[project_agent_runs project_agent_run_new project_agent_run_show project_agent_run_provenance],
      "projects/bundle_performance_dashboards_controller.rb" => [ :project_bundle_performance_dashboard ],
      "projects/cost_dashboards_controller.rb" => [ :project_cost_dashboard ],
      "projects/cost_snapshots_controller.rb" => [ :project_cost_snapshot ],
      "projects/quality_dashboards_controller.rb" => [ :project_quality_dashboard ],
      "projects/scaling_dashboards_controller.rb" => [ :project_scaling_dashboard ],
      "projects/roi_dashboards_controller.rb" => [ :project_roi_dashboard ],
      "projects/roi_benchmarks_controller.rb" => [ :project_roi_dashboard ],
      "knowledge/search_controller.rb" => %i[knowledge_search project_knowledge_search],
      "knowledge/browse_controller.rb" => %i[project_knowledge_browse project_knowledge_browse_show],
      "knowledge/artifacts_controller.rb" => [ :project_knowledge_artifact_show ],
      "knowledge/context_intake_controller.rb" => [ :project_context_intake ],
      "projects/cost_budgets_controller.rb" => [ :project_cost_dashboard ],
      "projects/change_intents_controller.rb" => [ :project_change_intent_show ],
      "projects/clarifying_questions_controller.rb" => [ :project_issue_clarifying_questions ],
      "projects/health_check_controller.rb" => [ :project_health_check ],
      "projects/connector_events_controller.rb" => [ :project_edit ],
      "projects/external_agent_runs_controller.rb" => [ :project_agent_runs ],
      "projects/issue_merge_subscriptions_controller.rb" => [ :project_show ],
      "projects/issues_controller.rb" => [ :project_show ],
      "projects/interop_settings_controller.rb" => [ :project_edit ],
      "projects/interoperability_imports_controller.rb" => [ :project_edit ],
      "projects/pr_templates_controller.rb" => [ :project_edit ],
      "projects/pre_commit_requirements_controller.rb" => [ :project_edit ],
      "projects/quality_thresholds_controller.rb" => [ :project_quality_dashboard ],
      "projects/service_containers_controller.rb" => [ :project_edit ],
      "projects/docker_host_preferences_controller.rb" => [ :docker_hosts ],
      "projects/mcp_servers_controller.rb" => [ :project_edit ],
      "projects/mutation_test_requirements_controller.rb" => [ :project_edit ],
      "projects/knowledge_recommendations_controller.rb" => [ :project_knowledge_recommendations ],
      "projects/screenshot_configs_controller.rb" => [ :project_edit ],
      "projects/convention_settings_controller.rb" => [ :project_convention_settings ],
      "projects/pdf_knowledge_imports_controller.rb" => [ :project_pdf_knowledge_import_new ],
      "admin/github_app/setup_controller.rb" => [ :admin_github_app_setup ],
      "github_app/installations_controller.rb" => [ :integrations ],
      "marketplace_entry_pdf_imports_controller.rb" => [ :marketplace_entry_pdf_import_new ]
    }.freeze

    def targets_for(path)
      return targets_for_javascript_registry if path == "app/javascript/controllers/index.js"

      if path.start_with?("app/javascript/controllers/")
        relative = path.delete_prefix("app/javascript/controllers/")
        explicit_targets = targets_for_javascript_controller(relative)
        return explicit_targets if explicit_targets.any?

        scanned = targets_for_stimulus_usage(relative)
        return scanned if scanned&.any?
      end

      return SHARED_TARGET_KEYS if shared_ui_file?(path)

      if path.start_with?("app/views/")
        targets_for_view(path.delete_prefix("app/views/"))
      elsif path.start_with?("app/components/")
        SHARED_TARGET_KEYS
      elsif path.start_with?("app/helpers/")
        targets_for_helper(path)
      elsif path.start_with?("app/controllers/")
        targets_for_controller(path.delete_prefix("app/controllers/"))
      elsif path.start_with?("public/")
        targets_for_public_file(path)
      else
        []
      end
    end

    def shared_ui_file?(path)
      path.start_with?("config/locales/") ||
        path.start_with?("app/javascript/") ||
        path.start_with?("app/frontend/") ||
        path.start_with?("app/assets/stylesheets/") ||
        path.start_with?("app/assets/builds/") ||
        path == "app/views/layouts/application.html.erb" ||
        path.start_with?("app/views/shared/") ||
        path == "app/helpers/application_helper.rb"
    end

    def targets_for_javascript_controller(relative_path)
      case relative_path
      when "clarifying_questions_controller.js" then [ :project_issue_clarifying_questions ]
      when "marketplace_picker_controller.js" then [ :project_agent_run_new ]
      else
        []
      end
    end

    def targets_for_javascript_registry
      explicit_targets = @changed_files
        .grep(%r{\Aapp/javascript/controllers/(?!index\.js\z)})
        .flat_map { |file| targets_for_javascript_controller(file.delete_prefix("app/javascript/controllers/")) }
        .uniq

      return explicit_targets if explicit_targets.any?

      SHARED_TARGET_KEYS
    end

    # Globs scanned to discover which views statically reference a Stimulus
    # controller via `data-controller`. Used to narrow a JS controller change to
    # the pages that actually mount it, instead of fanning out to every page.
    STIMULUS_SCAN_GLOBS = %w[app/views/**/*.erb app/components/**/*.erb app/components/**/*.rb].freeze

    # Returns target keys for the pages that statically mount the given Stimulus
    # controller, or nil to signal "cannot narrow" so the caller falls back to
    # the conservative shared-target behavior. Requires a repo_path to scan.
    def targets_for_stimulus_usage(relative_path)
      return nil if @repo_path.blank?

      identifier = stimulus_identifier(relative_path)
      return nil if identifier.nil?

      matches = stimulus_usage_index[identifier]
      return nil if matches.empty? # not referenced statically — stay conservative

      # Mounted on a globally rendered surface (layout, shared partial, component)
      # — a change can affect any page, so we cannot safely narrow.
      return SHARED_TARGET_KEYS if matches.any? { |file| global_surface?(file) }

      matches.flat_map { |file| targets_for_static_view(file) }.uniq
    end

    # Derives the Stimulus identifier from a controller file path, mirroring
    # Stimulus conventions: underscores become dashes and nested directories
    # become `--`. e.g. "foo/bar_baz_controller.js" => "foo--bar-baz".
    def stimulus_identifier(relative_path)
      return nil unless relative_path.end_with?("_controller.js")

      relative_path
        .delete_suffix("_controller.js")
        .split("/")
        .map { |segment| segment.tr("_", "-") }
        .join("--")
    end

    def stimulus_usage_index
      @stimulus_usage_index ||= STIMULUS_SCAN_GLOBS.each_with_object(Hash.new { |h, k| h[k] = [] }) do |glob, index|
        Dir.glob(File.join(@repo_path, glob)).each do |file|
          relative = file.delete_prefix("#{@repo_path}/")
          stimulus_identifiers_in(read_scrubbed(file)).each { |identifier| index[identifier] << relative }
        rescue SystemCallError, ArgumentError
          next # unreadable or undecodable file — skip
        end
      end
    end

    # Reads a file as scrubbed UTF-8 so a stray invalid byte sequence can never
    # raise from the regex scan and abort the whole capture-targets resolution.
    def read_scrubbed(file)
      File.read(file).scrub
    end

    # Extracts the Stimulus identifiers referenced in the given markup, covering
    # both the HTML attribute form (`data-controller="a b"`) and the Rails
    # tag-helper hash form (`data: { controller: "a" }` / `controller: "a"`).
    def stimulus_identifiers_in(content)
      content
        .scan(/(?:data-controller=|\bcontroller:\s*)("|')([^"']*)\1/)
        .flat_map { |_quote, value| value.split(/\s+/) }
        .uniq
    end

    def global_surface?(file)
      file.start_with?("app/components/") ||
        file.start_with?("app/views/layouts/") ||
        file.start_with?("app/views/shared/") ||
        layout_rendered_partials.include?(file)
    end

    LAYOUT_GLOB = "app/views/layouts/**/*.erb"

    # Partials rendered directly from a layout are mounted on every page that
    # uses that layout, so a Stimulus controller living in one cannot be narrowed
    # to a single page (e.g. the notification bell rendered into the global nav).
    # Over-matching here only widens capture, which is safe.
    def layout_rendered_partials
      @layout_rendered_partials ||= build_layout_rendered_partials
    end

    def build_layout_rendered_partials
      return Set.new if @repo_path.blank?

      Dir.glob(File.join(@repo_path, LAYOUT_GLOB)).each_with_object(Set.new) do |layout, set|
        read_scrubbed(layout).scan(/render\b\s*\(?\s*(?:partial:\s*)?("|')([^"']+)\1/) do |_quote, partial|
          dir, _, name = partial.rpartition("/")
          next if name.empty?

          set << "app/views/#{dir.empty? ? '' : "#{dir}/"}_#{name}.html.erb"
        end
      rescue SystemCallError, ArgumentError
        next
      end
    end

    def targets_for_static_view(file)
      return SHARED_TARGET_KEYS if global_surface?(file)
      return targets_for_view(file.delete_prefix("app/views/")) if file.start_with?("app/views/")

      SHARED_TARGET_KEYS
    end

    def targets_for_helper(path)
      helper_name = File.basename(path).delete_suffix("_helper.rb")
      explicit_targets = HELPER_TARGETS[helper_name]
      return explicit_targets if explicit_targets

      targets_for_view("#{helper_name}/index.html.erb")
    end

    def targets_for_view(relative_path)
      case relative_path
      when "devise/sessions/new.html.erb" then [ :sign_in ]
      when /\Adevise\/registrations\// then [ :sign_up ]
      when /\Adevise\/passwords\// then [ :forgot_password ]
      when /\Adevise\/confirmations\// then [ :confirmation ]
      when /\Adevise\/unlocks\// then [ :unlock ]
      when /\Adevise\/shared\// then %i[sign_in sign_up forgot_password confirmation unlock]
      when /\Adevise\// then [ :sign_in ]
      when /\Adashboard\//, "dashboard/show.html.erb" then [ :dashboard ]
      when /\Ahome\// then [ :dashboard ]
      when /\Anotifications\// then [ :notifications ]
      when /\Aonboarding\// then [ :onboarding ]
      when /\Afree_models\// then [ :free_models_catalog ]
      when /\Aintegrations\// then integrations_targets(relative_path.delete_prefix("integrations/"))
      when /\Aadmin\/github_app\/setup\// then [ :admin_github_app_setup ]
      when /\Aintegration_credentials\// then rest_resource_targets(relative_path, "integration_credentials", index: :integration_credentials, new: :integration_credential_new, show: :integration_credential_show, edit: :integration_credential_show)
      when /\Arunner_credentials\// then rest_resource_targets(relative_path, "runner_credentials", index: :runner_credentials, new: :runner_credential_new, show: :runner_credential_show, edit: :runner_credential_show)
      when /\Aclaude_login_sessions\// then rest_resource_targets(relative_path, "claude_login_sessions", index: :claude_login_session_new, new: :claude_login_session_new, show: :claude_login_session_show, edit: :claude_login_session_show)
      when /\Acodex_login_sessions\// then rest_resource_targets(relative_path, "codex_login_sessions", index: :codex_login_session_new, new: :codex_login_session_new, show: :codex_login_session_show, edit: :codex_login_session_show)
      when /\Agithub_installations\// then github_installation_targets(relative_path.delete_prefix("github_installations/"))
      when /\Agithub_tokens\// then rest_resource_targets(relative_path, "github_tokens", index: :github_tokens, new: :github_token_new, show: :github_token_show, edit: :github_token_show)
      when /\Alinear_tokens\// then rest_resource_targets(relative_path, "linear_tokens", index: :linear_tokens, new: :linear_token_new, show: :linear_token_show, edit: :linear_token_show)
      when /\Auser_settings\// then [ :user_settings ]
      when /\Aaccounts\/compliance_dashboards\// then [ :account_compliance_dashboard ]
      when /\Aaccounts\/operations_dashboards\// then [ :account_operations_dashboard ]
      when /\Aaccounts\/roi_dashboards\// then [ :account_roi_dashboard ]
      when /\Aaccounts\/egress_allowlist_entries\// then [ :account_egress_allowlist ]
      when /\Aaccounts\// then [ :account ]
      when /\Aaccount_audit_logs\// then [ :account_audit_logs ]
      when /\Aremediation_decisions\// then [ :remediation_decision_show ]
      when /\Atenant_configurations\// then [ :tenant_configuration ]
      when /\Aprovider_api_keys\// then rest_resource_targets(relative_path, "provider_api_keys", index: :provider_api_keys, new: :provider_api_key_new, show: :provider_api_key_show, edit: :provider_api_key_edit)
      when /\Aproviders\// then providers_targets(relative_path.delete_prefix("providers/"))
      when /\Arunners\// then providers_targets(relative_path.delete_prefix("runners/"))
      when /\Aservice_containers\// then rest_resource_targets(relative_path, "service_containers", index: :service_containers, new: :service_container_new, show: :service_container_show, edit: :service_container_edit)
      when /\Adocker_hosts\// then rest_resource_targets(relative_path, "docker_hosts", index: :docker_hosts, new: :docker_hosts, show: :docker_host_show, edit: :docker_host_edit)
      when /\Amarketplace_entries\// then rest_resource_targets(relative_path, "marketplace_entries", index: :marketplace_entries, new: :marketplace_entry_new, show: :marketplace_entry_show, edit: :marketplace_entry_edit)
      when /\Amarketplace_entry_pdf_imports\// then [ :marketplace_entry_pdf_import_new ]
      when /\Amcp_server_definitions\// then rest_resource_targets(relative_path, "mcp_server_definitions", index: :mcp_server_definitions, new: :mcp_server_definition_new, show: :mcp_server_definition_show, edit: :mcp_server_definition_edit)
      when "agent_runs/_detail.html.erb", "agent_runs/_detail_actions.html.erb" then [ :project_agent_run_show ]
      when /\Aagent_runs\// then [ :agent_runs ]
      when /\Aprompt_reviews\// then prompt_review_targets(relative_path.delete_prefix("prompt_reviews/"))
      when /\Aplan_reviews\// then [ :plan_reviews ]
      when /\Astrategy_reviews\// then strategy_review_targets(relative_path.delete_prefix("strategy_reviews/"))
      when /\Aab_tests\// then ab_test_targets(relative_path.delete_prefix("ab_tests/"))
      when /\Aprompts\// then prompts_targets(relative_path.delete_prefix("prompts/"))
      when /\Astyle_guides\// then rest_resource_targets(relative_path, "style_guides", index: :style_guides, new: :style_guide_new, show: :style_guide_show, edit: :style_guide_edit)
      when /\Achat_sessions\// then chat_session_targets(relative_path.delete_prefix("chat_sessions/"))
      when /\Achat_messages\// then [ :chat_session_show ]
      when /\Aknowledge\/artifacts\// then [ :project_knowledge_artifact_show ]
      when /\Aknowledge\/browse\// then knowledge_browse_targets(relative_path.delete_prefix("knowledge/browse/"))
      when /\Aknowledge\/context_intake\// then [ :project_context_intake ]
      when /\Aprojects\/pdf_knowledge_imports\// then [ :project_pdf_knowledge_import_new ]
      when /\Aknowledge\/search\// then knowledge_search_targets(relative_path.delete_prefix("knowledge/search/"))
      when /\Aquality_dashboards\// then [ :quality_dashboard ]
      when "projects/agent_runs/provenance.html.erb" then [ :project_agent_run_provenance ]
      when /\Aprojects\/agent_runs\// then rest_resource_targets(relative_path, "projects/agent_runs", index: :project_agent_runs, new: :project_agent_run_new, show: :project_agent_run_show, edit: :project_agent_run_show)
      when /\Aprojects\/bundle_performance_dashboards\// then [ :project_bundle_performance_dashboard ]
      when /\Aprojects\/cost_dashboards\// then [ :project_cost_dashboard ]
      when /\Aprojects\/cost_snapshots\// then [ :project_cost_snapshot ]
      when /\Aworkflow_statuses\// then [ :workflow_status ]
      when /\Aprojects\/quality_dashboards\// then [ :project_quality_dashboard ]
      when /\Aprojects\/scaling_dashboards\// then [ :project_scaling_dashboard ]
      when /\Aprojects\/roi_dashboards\// then [ :project_roi_dashboard ]
      when /\Aprojects\/convention_settings\// then [ :project_convention_settings ]
      when /\Aprojects\/knowledge_recommendations\// then [ :project_knowledge_recommendations ]
      when /\Apreviews\// then [ :preview_session_show ]
      when /\Aprojects\/health_check\// then [ :project_health_check ]
      when /\Aprojects\/egress_allowlist_entries\// then [ :project_egress_allowlist ]
      when /\Aprojects\// then projects_targets(relative_path.delete_prefix("projects/"))
      else
        []
      end
    end

    def prompt_review_targets(leaf)
      case leaf
      when "queue.html.erb" then [ :prompt_reviews_queue ]
      when "index.html.erb" then [ :prompt_reviews ]
      else
        [ :prompt_review_show ]
      end
    end

    def strategy_review_targets(leaf)
      case leaf
      when "queue.html.erb" then [ :strategy_reviews_queue ]
      when "index.html.erb" then [ :strategy_reviews ]
      else
        [ :strategy_review_show ]
      end
    end

    def ab_test_targets(leaf)
      case leaf
      when "index.html.erb" then [ :ab_tests ]
      when "new.html.erb" then [ :ab_test_new ]
      else
        [ :ab_test_show ]
      end
    end

    def chat_session_targets(leaf)
      case leaf
      when "index.html.erb" then [ :chat_sessions ]
      else
        [ :chat_session_show ]
      end
    end

    def knowledge_browse_targets(leaf)
      case leaf
      when "index.html.erb" then [ :project_knowledge_browse ]
      else
        [ :project_knowledge_browse_show ]
      end
    end

    def integrations_targets(leaf)
      case leaf
      when "index.html.erb" then [ :integrations ]
      when "new.html.erb" then [ :integrations_new ]
      else
        [ :integrations ]
      end
    end

    def github_installation_targets(leaf)
      case leaf
      when "index.html.erb" then [ :github_installations ]
      when "show.html.erb" then [ :github_installation_show ]
      when "migrate_projects.html.erb" then [ :github_installation_migrate_projects ]
      else
        [ :github_installation_show ]
      end
    end

    def providers_targets(leaf)
      case leaf
      when "index.html.erb", "_settings.html.erb", "_usage_stats.html.erb" then [ :providers ]
      when "new.html.erb" then [ :providers_new ]
      when "edit.html.erb" then [ :providers_edit ]
      when /\A_/ then %i[providers_new providers_edit]
      else
        [ :providers ]
      end
    end

    def prompts_targets(leaf)
      case leaf
      when "index.html.erb" then [ :prompts ]
      when "new.html.erb" then [ :prompt_new ]
      when "show.html.erb" then [ :prompt_show ]
      when "edit.html.erb" then [ :prompt_edit ]
      when "diff.html.erb" then [ :prompt_diff ]
      when /\A_/ then %i[prompt_new prompt_edit] # Partials used in form pages
      else
        [ :prompt_show ]
      end
    end

    # Partials rendered on the projects/show page (Turbo frames, collections, etc.)
    PROJECT_SHOW_PARTIALS = %w[
      _issues _issue _pull_requests _pull_request _knowledge _stats
      _quality_summary _cost_snapshot _agent_runs _agent_run
      _recent_merged_pull_requests _issue_merge_subscription
      _issue_pause_toggle
    ].freeze

    def projects_targets(leaf)
      case leaf
      when "index.html.erb" then [ :projects ]
      when "new.html.erb" then [ :project_new ]
      when "show.html.erb" then [ :project_show ]
      when "edit.html.erb" then [ :project_edit ]
      when "clarifying_questions/show.html.erb" then [ :project_issue_clarifying_questions ]
      when "change_intents/show.html.erb" then [ :project_change_intent_show ]
      when /\A_/
        base = File.basename(leaf, ".html.erb")
        if PROJECT_SHOW_PARTIALS.include?(base)
          [ :project_show ]
        elsif base.end_with?("_index")
          [ :projects ]
        else
          %i[project_new project_edit]
        end
      else
        [ :project_show ]
      end
    end

    def knowledge_search_targets(leaf)
      case leaf
      when "index.html.erb" then [ :knowledge_search ]
      else
        [ :project_knowledge_search ]
      end
    end

    def targets_for_controller(relative_path)
      # Skip concerns — they don't map to specific pages
      return [] if relative_path.start_with?("concerns/")
      # Skip API controllers — they don't render HTML
      return [] if relative_path.start_with?("api/")
      # Skip health check controller — infrastructure only
      return [] if relative_path == "health_controller.rb"

      NESTED_CONTROLLER_TARGETS[relative_path] ||
        CONTROLLER_TARGETS[File.basename(relative_path)] ||
        [] # Return empty to surface unmapped controllers via UnmappedUiChangeError
    end

    def targets_for_public_file(path)
      case path.delete_prefix("public/")
      when "icon.png" then [ :public_icon_png ]
      when "icon.svg" then [ :public_icon_svg ]
      when "400.html" then [ :public_400 ]
      when "404.html" then [ :public_404 ]
      when "406-unsupported-browser.html" then [ :public_406_unsupported_browser ]
      when "422.html" then [ :public_422 ]
      when "500.html" then [ :public_500 ]
      else
        SHARED_TARGET_KEYS
      end
    end

    def rest_resource_targets(relative_path, prefix, index:, new:, show:, edit:)
      leaf = relative_path.delete_prefix("#{prefix}/")

      case leaf
      when "index.html.erb" then [ index ]
      when "new.html.erb" then [ new ]
      when "show.html.erb" then [ show ]
      when "edit.html.erb" then [ edit ]
      when /\A_/ then [ new, edit ].uniq # Partials are typically rendered from new/edit pages
      else
        [ show ]
      end
    end
  end
end
