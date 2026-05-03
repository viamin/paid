# frozen_string_literal: true

module Screenshots
  class CaptureTargets
    UnmappedUiChangeError = Class.new(StandardError)

    Target = Struct.new(:slug, :path_builder, :requires_auth, keyword_init: true) do
      def path(seed_data)
        path_builder.respond_to?(:call) ? path_builder.call(seed_data) : path_builder
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
      service_containers
      onboarding
      user_settings
      quality_dashboard
    ].freeze

    HELPER_TARGETS = {
      "application" => SHARED_TARGET_KEYS,
      "cost_dashboard" => %i[project_cost_dashboard project_cost_snapshot],
      "integrations" => [ :integrations ],
      "knowledge" => %i[knowledge_search project_knowledge_search project_knowledge_browse project_context_intake],
      "quality_metrics" => %i[quality_dashboard project_quality_dashboard],
      "workflow" => [ :workflow_status ]
    }.freeze

    TARGETS = {
      sign_in: Target.new(slug: "sign_in", path_builder: "/users/sign_in", requires_auth: false),
      dashboard: Target.new(slug: "dashboard", path_builder: "/dashboard", requires_auth: true),
      notifications: Target.new(slug: "notifications", path_builder: "/notifications", requires_auth: true),
      onboarding: Target.new(slug: "onboarding", path_builder: "/onboarding", requires_auth: true),
      integrations: Target.new(slug: "integrations", path_builder: "/integrations", requires_auth: true),
      integration_credentials: Target.new(slug: "integration_credentials", path_builder: "/integration_credentials", requires_auth: true),
      integration_credential_new: Target.new(slug: "integration_credential_new", path_builder: "/integration_credentials/new", requires_auth: true),
      integration_credential_show: Target.new(slug: "integration_credential_show", path_builder: ->(seed_data) { "/integration_credentials/#{seed_data.fetch(:integration_credential).id}" }, requires_auth: true),
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
      tenant_configuration: Target.new(slug: "tenant_configuration", path_builder: "/tenant_configuration/edit", requires_auth: true),
      providers: Target.new(slug: "providers", path_builder: "/providers", requires_auth: true),
      providers_new: Target.new(slug: "providers_new", path_builder: "/providers/new?auth_type=subscription", requires_auth: true),
      providers_edit: Target.new(slug: "providers_edit", path_builder: ->(seed_data) { "/providers/#{seed_data.fetch(:provider).id}/edit" }, requires_auth: true),
      service_containers: Target.new(slug: "service_containers", path_builder: "/service_containers", requires_auth: true),
      service_container_new: Target.new(slug: "service_container_new", path_builder: "/service_containers/new", requires_auth: true),
      service_container_show: Target.new(slug: "service_container_show", path_builder: ->(seed_data) { "/service_containers/#{seed_data.fetch(:service_container).id}" }, requires_auth: true),
      service_container_edit: Target.new(slug: "service_container_edit", path_builder: ->(seed_data) { "/service_containers/#{seed_data.fetch(:service_container).id}/edit" }, requires_auth: true),
      agent_runs: Target.new(slug: "agent_runs", path_builder: "/agent_runs", requires_auth: true),
      prompts: Target.new(slug: "prompts", path_builder: "/prompts", requires_auth: true),
      prompt_reviews_queue: Target.new(slug: "prompt_reviews_queue", path_builder: "/prompt_reviews", requires_auth: true),
      prompt_reviews: Target.new(slug: "prompt_reviews", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/reviews" }, requires_auth: true),
      prompt_review_show: Target.new(slug: "prompt_review_show", path_builder: ->(seed_data) { "/prompts/#{seed_data.fetch(:prompt).id}/reviews/#{seed_data.fetch(:pending_prompt_version).id}" }, requires_auth: true),
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
      projects: Target.new(slug: "projects", path_builder: "/projects", requires_auth: true),
      project_new: Target.new(slug: "project_new", path_builder: "/projects/new", requires_auth: true),
      project_show: Target.new(slug: "project_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}" }, requires_auth: true),
      project_edit: Target.new(slug: "project_edit", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/edit" }, requires_auth: true),
      project_agent_runs: Target.new(slug: "project_agent_runs", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs" }, requires_auth: true),
      project_agent_run_new: Target.new(slug: "project_agent_run_new", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs/new" }, requires_auth: true),
      project_agent_run_show: Target.new(slug: "project_agent_run_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs/#{seed_data.fetch(:agent_run).id}" }, requires_auth: true),
      project_quality_dashboard: Target.new(slug: "project_quality_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/quality_dashboard" }, requires_auth: true),
      project_cost_snapshot: Target.new(slug: "project_cost_snapshot", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/cost_snapshot" }, requires_auth: true),
      project_cost_dashboard: Target.new(slug: "project_cost_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/cost_dashboard" }, requires_auth: true),
      project_context_intake: Target.new(slug: "project_context_intake", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/context_intake" }, requires_auth: true),
      project_knowledge_search: Target.new(slug: "project_knowledge_search", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/knowledge/search" }, requires_auth: true),
      project_knowledge_browse: Target.new(slug: "project_knowledge_browse", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/knowledge/browse" }, requires_auth: true),
      project_knowledge_browse_show: Target.new(slug: "project_knowledge_browse_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/knowledge/browse/route" }, requires_auth: true),
      project_knowledge_artifact_show: Target.new(slug: "project_knowledge_artifact_show", path_builder: ->(seed_data) { "/knowledge_artifacts/#{seed_data.fetch(:knowledge_artifact).id}" }, requires_auth: true),
      workflow_status: Target.new(slug: "workflow_status", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/workflow_status" }, requires_auth: true)
    }.freeze

    def self.call(changed_files:)
      new(changed_files: changed_files).call
    end

    def initialize(changed_files:)
      @changed_files = Array(changed_files)
    end

    def call
      return materialize(SHARED_TARGET_KEYS) if @changed_files.empty?

      target_keys = @changed_files.flat_map { |path| targets_for(path) }.uniq
      unresolved_files = @changed_files.reject { |path| targets_for(path).any? }

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

    def targets_for(path)
      return SHARED_TARGET_KEYS if shared_ui_file?(path)

      if path.start_with?("app/views/")
        targets_for_view(path.delete_prefix("app/views/"))
      elsif path.start_with?("app/components/")
        SHARED_TARGET_KEYS
      elsif path.start_with?("app/helpers/")
        targets_for_helper(path)
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

    def targets_for_helper(path)
      helper_name = File.basename(path).delete_suffix("_helper.rb")
      explicit_targets = HELPER_TARGETS[helper_name]
      return explicit_targets if explicit_targets

      targets_for_view("#{helper_name}/index.html.erb")
    end

    def targets_for_view(relative_path)
      case relative_path
      when "devise/sessions/new.html.erb" then [ :sign_in ]
      when /\Adevise\// then [ :sign_in ]
      when /\Adashboard\//, "dashboard/show.html.erb" then [ :dashboard ]
      when /\Ahome\// then [ :dashboard ]
      when /\Anotifications\// then [ :notifications ]
      when /\Aonboarding\// then [ :onboarding ]
      when /\Aintegrations\// then [ :integrations ]
      when /\Aintegration_credentials\// then rest_resource_targets(relative_path, "integration_credentials", index: :integration_credentials, new: :integration_credential_new, show: :integration_credential_show, edit: :integration_credential_show)
      when /\Agithub_tokens\// then rest_resource_targets(relative_path, "github_tokens", index: :github_tokens, new: :github_token_new, show: :github_token_show, edit: :github_token_show)
      when /\Alinear_tokens\// then rest_resource_targets(relative_path, "linear_tokens", index: :linear_tokens, new: :linear_token_new, show: :linear_token_show, edit: :linear_token_show)
      when /\Auser_settings\// then [ :user_settings ]
      when /\Atenant_configurations\// then [ :tenant_configuration ]
      when /\Aprovider_api_keys\// then rest_resource_targets(relative_path, "provider_api_keys", index: :provider_api_keys, new: :provider_api_key_new, show: :provider_api_key_show, edit: :provider_api_key_edit)
      when /\Aproviders\// then rest_resource_targets(relative_path, "providers", index: :providers, new: :providers_new, show: :providers, edit: :providers_edit)
      when /\Aservice_containers\// then rest_resource_targets(relative_path, "service_containers", index: :service_containers, new: :service_container_new, show: :service_container_show, edit: :service_container_edit)
      when /\Aagent_runs\// then [ :agent_runs ]
      when /\Aprompt_reviews\// then prompt_review_targets(relative_path.delete_prefix("prompt_reviews/"))
      when /\Aab_tests\// then ab_test_targets(relative_path.delete_prefix("ab_tests/"))
      when /\Aprompts\// then [ :prompts ]
      when /\Astyle_guides\// then rest_resource_targets(relative_path, "style_guides", index: :style_guides, new: :style_guide_new, show: :style_guide_show, edit: :style_guide_edit)
      when /\Achat_sessions\// then chat_session_targets(relative_path.delete_prefix("chat_sessions/"))
      when /\Achat_messages\// then [ :chat_session_show ]
      when /\Aknowledge\/artifacts\// then [ :project_knowledge_artifact_show ]
      when /\Aknowledge\/browse\// then knowledge_browse_targets(relative_path.delete_prefix("knowledge/browse/"))
      when /\Aknowledge\/context_intake\// then [ :project_context_intake ]
      when /\Aknowledge\/search\// then knowledge_search_targets(relative_path.delete_prefix("knowledge/search/"))
      when /\Aquality_dashboards\// then [ :quality_dashboard ]
      when /\Aprojects\/agent_runs\// then rest_resource_targets(relative_path, "projects/agent_runs", index: :project_agent_runs, new: :project_agent_run_new, show: :project_agent_run_show, edit: :project_agent_run_show)
      when /\Aprojects\/cost_dashboards\// then [ :project_cost_dashboard ]
      when /\Aprojects\/cost_snapshots\// then [ :project_cost_snapshot ]
      when /\Aworkflow_statuses\// then [ :workflow_status ]
      when /\Aprojects\/quality_dashboards\// then [ :project_quality_dashboard ]
      when /\Aprojects\// then rest_resource_targets(relative_path, "projects", index: :projects, new: :project_new, show: :project_show, edit: :project_edit)
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

    def knowledge_search_targets(leaf)
      case leaf
      when "index.html.erb" then [ :knowledge_search ]
      else
        [ :project_knowledge_search ]
      end
    end

    def rest_resource_targets(relative_path, prefix, index:, new:, show:, edit:)
      leaf = relative_path.delete_prefix("#{prefix}/")

      case leaf
      when "index.html.erb" then [ index ]
      when "new.html.erb" then [ new ]
      when "show.html.erb" then [ show ]
      when "edit.html.erb" then [ edit ]
      else
        [ show ]
      end
    end
  end
end
