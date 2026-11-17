# frozen_string_literal: true

module Tools
  # @spec AUTOMATION-PHASES-009
  class ExtendContinuationGrant < BaseTool
    authorize :update?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "extend_continuation_grant"
    def self.write_operation? = true
    def self.description = "Extend an active continuation grant to an allowed endpoint; extending through merge requires merge-delegation permission."

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, grant_id: { type: "integer" }, endpoint: { type: "string", enum: Automation::Phases::CONTINUATION_ENDPOINTS }, confirmed: { type: "boolean" } }, required: %w[project_id grant_id endpoint confirmed] }
    end

    def perform(project_id:, grant_id:, endpoint:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to extend a continuation grant" unless confirmed

      project = project_for(project_id)
      grant = project.work_item_continuation_grants.find(grant_id)
      plan = Automation::ManualStart::Plan.call(project:, user:, phase: grant.start_phase, endpoint:, continuation_selected: true)
      extended = grant.extend_to!(endpoint: plan.endpoint)
      raise ArgumentError, "Continuation grant is inactive or already covers that endpoint." unless extended

      { extended:, grant: Automation::PhaseSettings::Projection.new(project:).grant_payload(grant), continuation_notice: plan.notice.selection_summary }
    rescue Automation::ManualStart::Plan::Error => error
      raise ArgumentError, error.message
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
