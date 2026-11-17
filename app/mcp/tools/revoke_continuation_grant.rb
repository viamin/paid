# frozen_string_literal: true

module Tools
  # @spec AUTOMATION-PHASES-008
  class RevokeContinuationGrant < BaseTool
    authorize :update?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "revoke_continuation_grant"
    def self.write_operation? = true
    def self.description = "Revoke an active continuation grant. This does not disable independent project automation."

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, grant_id: { type: "integer" }, confirmed: { type: "boolean" } }, required: %w[project_id grant_id confirmed] }
    end

    def perform(project_id:, grant_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to revoke a continuation grant" unless confirmed

      project = project_for(project_id)
      grant = project.work_item_continuation_grants.find(grant_id)
      { revoked: grant.revoke!(user: user), grant: Automation::PhaseSettings::Projection.new(project:).grant_payload(grant), continuation_notice: Automation::PhaseSettings::Projection::REVOCATION_NOTICE }
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
