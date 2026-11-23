# frozen_string_literal: true

module Tools
  # @spec AUTO-MERGE-012
  class UpdateTechnicalMergeBlocker < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "update_technical_merge_blocker"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.description
      "Record or resolve a Paid-internal technical PR blocker without labels or human approval. " \
        "Resolution requires verified evidence, the current PR head and the inspected entry version. Requires confirmation."
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, issue_id: { type: "integer" },
        action: { type: "string", enum: %w[record resolve] }, key: { type: "string" },
        head_sha: { type: "string" }, reason: { type: "string" }, owner_issue_id: { type: "integer" },
        release_condition: { type: "string" }, version: { type: "string" }, evidence: { type: "string" },
        confirmed: { type: "boolean" }
      }, required: %w[project_id issue_id action key head_sha confirmed] }
    end

    def perform(project_id:, issue_id:, action:, key:, head_sha:, confirmed: false,
                reason: nil, owner_issue_id: nil, release_condition: nil, version: nil, evidence: nil)
      raise ArgumentError, "Confirmation required" unless confirmed

      issue = project_for(project_id).issues.pull_requests_only.find(issue_id)
      case action
      when "record"
        PullRequests::TechnicalMergeBlockers.record!(issue:, actor: current_user, key:, head_sha:,
          reason:, owner_issue_id:, release_condition:)
      when "resolve"
        PullRequests::TechnicalMergeBlockers.resolve!(issue:, actor: current_user, key:, version:, head_sha:, evidence:)
      else
        raise ArgumentError, "Unsupported technical blocker action"
      end
      { issue_id: issue.id, technical_merge_blockers: PullRequests::TechnicalMergeBlockers.entries(issue.reload) }
    end

    private

    def project_for(id)
      @projects_by_id ||= {}
      @projects_by_id[id] ||= policy_scope(Project).find(id)
    end
  end
end
