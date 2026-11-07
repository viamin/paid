# frozen_string_literal: true

module Tools
  class GetProject < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    def self.tool_name = "get_project"

    def self.description
      "Get project details including repo info, settings, and recent activity."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" }
        },
        required: [ "project_id" ]
      }
    end

    def perform(project_id:)
      # @spec LID-RUNS-006
      # @spec GITHUB-SYNC-009
      project = project_for(project_id)

      recent_runs = project.agent_runs.recent.limit(5)

      {
        id: project.id,
        name: project.name,
        repo: project.full_name,
        active: project.active,
        default_branch: project.default_branch,
        lid: Interop::ExternalAgentLidContract.call(project: project),
        github_diagnostics: Projects::GithubDiagnostics.call(project: project),
        delegation: delegation_payload(project),
        recent_runs: recent_runs.map { |r| run_summary(r) },
        created_at: project.created_at,
        updated_at: project.updated_at
      }.compact
    end

    private

    # Delegated authority through the shared delegation projection, so tool
    # consumers see each authorization's own effective policy instead of a
    # project-wide authority figure. Absent entirely while the project
    # delegation gate is off.
    # @spec PROJECT-DELEGATION-005
    def delegation_payload(project)
      projection = ProjectDelegation::Projection.call(project: project)
      return unless projection.enabled

      projection.to_h
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def run_summary(run)
      {
        id: run.id,
        status: run.status,
        goal: run.goal,
        issue_id: run.issue_id,
        created_at: run.created_at
      }
    end
  end
end
