# frozen_string_literal: true

module Tools
  # @spec PARTIAL-CLOSEOUT-060
  class ManageSharedDeliveryEvidence < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "manage_shared_delivery_evidence"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.description = "Associate or revoke revision-pinned shared delivery evidence. Requires explicit confirmation."

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, issue_id: { type: "integer" },
        pull_request_id: { type: "integer", description: "Required when associating" },
        action: { type: "string", enum: %w[associate revoke] },
        confirmed: { type: "boolean" }
      }, required: %w[project_id issue_id action confirmed] }
    end

    def perform(project_id:, issue_id:, action:, pull_request_id: nil, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to manage shared delivery evidence" unless confirmed

      project = project_for(project_id)
      issue = project.issues.issues_only.find(issue_id)
      association = manage(project, issue, action:, pull_request_id:)
      serialize(association)
    end

    private

    def manage(project, issue, action:, pull_request_id:)
      case action
      when "associate"
        raise ArgumentError, "pull_request_id is required when associating" if pull_request_id.blank?

        pull_request = project.issues.pull_requests_only.find(pull_request_id)
        Issues::AssociateSharedDeliveryEvidence.call(issue:, pull_request:, actor: user)
      when "revoke"
        revoke(issue)
      else
        raise ArgumentError, "action must be associate or revoke"
      end
    end

    def revoke(issue)
      association = issue.shared_delivery_evidence_associations.find_by!(revoked_at: nil)
      association.update!(revoked_at: Time.current)
      association
    end

    def serialize(association)
      { id: association.id, issue_id: association.issue_id,
        pull_request_url: association.pull_request_url, revision: association.revision,
        active: association.revoked_at.nil?, revoked_at: association.revoked_at }
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
