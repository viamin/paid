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

    TARGETS = {
      sign_in: Target.new(slug: "sign_in", path_builder: "/users/sign_in", requires_auth: false),
      dashboard: Target.new(slug: "dashboard", path_builder: "/dashboard", requires_auth: true),
      notifications: Target.new(slug: "notifications", path_builder: "/notifications", requires_auth: true),
      onboarding: Target.new(slug: "onboarding", path_builder: "/onboarding", requires_auth: true),
      integrations: Target.new(slug: "integrations", path_builder: "/integrations", requires_auth: true),
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
      quality_dashboard: Target.new(slug: "quality_dashboard", path_builder: "/quality_dashboard", requires_auth: true),
      projects: Target.new(slug: "projects", path_builder: "/projects", requires_auth: true),
      project_new: Target.new(slug: "project_new", path_builder: "/projects/new", requires_auth: true),
      project_show: Target.new(slug: "project_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}" }, requires_auth: true),
      project_edit: Target.new(slug: "project_edit", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/edit" }, requires_auth: true),
      project_agent_runs: Target.new(slug: "project_agent_runs", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs" }, requires_auth: true),
      project_agent_run_new: Target.new(slug: "project_agent_run_new", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs/new" }, requires_auth: true),
      project_agent_run_show: Target.new(slug: "project_agent_run_show", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/agent_runs/#{seed_data.fetch(:agent_run).id}" }, requires_auth: true),
      project_quality_dashboard: Target.new(slug: "project_quality_dashboard", path_builder: ->(seed_data) { "/projects/#{seed_data.fetch(:project).id}/quality_dashboard" }, requires_auth: true)
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
      targets_for_view("#{helper_name}/index.html.erb")
    end

    def targets_for_view(relative_path)
      case relative_path
      when "devise/sessions/new.html.erb" then [ :sign_in ]
      when /\Adashboard\//, "dashboard/show.html.erb" then [ :dashboard ]
      when /\Anotifications\// then [ :notifications ]
      when /\Aonboarding\// then [ :onboarding ]
      when /\Aintegrations\// then [ :integrations ]
      when /\Auser_settings\// then [ :user_settings ]
      when /\Atenant_configurations\// then [ :tenant_configuration ]
      when /\Aproviders\// then rest_resource_targets(relative_path, "providers", index: :providers, new: :providers_new, show: :providers, edit: :providers_edit)
      when /\Aservice_containers\// then rest_resource_targets(relative_path, "service_containers", index: :service_containers, new: :service_container_new, show: :service_container_show, edit: :service_container_edit)
      when /\Aagent_runs\// then [ :agent_runs ]
      when /\Aprompts\// then [ :prompts ]
      when /\Aquality_dashboards\// then [ :quality_dashboard ]
      when /\Aprojects\/agent_runs\// then rest_resource_targets(relative_path, "projects/agent_runs", index: :project_agent_runs, new: :project_agent_run_new, show: :project_agent_run_show, edit: :project_agent_run_show)
      when /\Aprojects\/quality_dashboards\// then [ :project_quality_dashboard ]
      when /\Aprojects\// then rest_resource_targets(relative_path, "projects", index: :projects, new: :project_new, show: :project_show, edit: :project_edit)
      else
        []
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
