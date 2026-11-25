# frozen_string_literal: true

module Tools
  # @spec RUST-SDK-BUILD-013
  class BuildPinnedRustSdkCore < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "build_pinned_rust_sdk_core"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.requires_agent_run? = true
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.description
      "Run the fixed, isolated Rust SDK Core baseline through Paid's selected backend. Requires confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project whose authorized agent requests the build" },
          agent_run_id: { type: "integer", description: "The agent run whose selected backend owns the build" },
          confirmed: { type: "boolean", description: "Must be true to start the isolated build" }
        },
        required: %w[project_id agent_run_id confirmed]
      }
    end

    def perform(project_id:, agent_run_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to start the isolated build" unless confirmed

      agent_run = agent_run_for(project_id, agent_run_id)
      host = agent_run.workspace_volume_host
      raise ArgumentError, "The acting agent run has no selected container backend" if host.blank?

      SdkBuildEnvironments::PinnedCoreBuild.call(backend: Containers.backend_for(host))
    end

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    rescue ActiveRecord::RecordNotFound
      raise Pundit::NotAuthorizedError, "Project not found or not accessible"
    end

    def agent_run_for(project_id, agent_run_id)
      unless agent_run&.id.to_s == agent_run_id.to_s
        raise Pundit::NotAuthorizedError, "Agent run not found or not accessible"
      end

      project_for(project_id).agent_runs.where(id: agent_run.id, initiating_user: user).find(agent_run_id)
    rescue ActiveRecord::RecordNotFound
      raise Pundit::NotAuthorizedError, "Agent run not found or not accessible"
    end
  end
end
