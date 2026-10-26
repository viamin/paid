# frozen_string_literal: true

module Tools
  # @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Prepare a bounded, report-only verification audit. Confirmation queues it; it never starts a repair."

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } }, source_references: { type: "array", items: { type: "string" } }, target_revision: { type: "string" }, budget: { type: "object" }, checks: { type: "array" }, omissions: { type: "array" }, residual_gaps: { type: "array" } }, required: %w[project_id obligation_ids source_references target_revision budget checks omissions residual_gaps] }
    end

    def perform(**arguments)
      project = project_for(arguments.fetch(:project_id))
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      plan = LayeredVerification::Plans::Build.call(
        checks: arguments.fetch(:checks), omissions: arguments.fetch(:omissions), residual_gaps: arguments.fetch(:residual_gaps)
      )
      preview(project:, arguments:, plan:)
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "decision must be approve or deny" unless %i[approve deny].include?(decision)
      return { status: "cancelled" } if decision == :deny

      arguments = pending_result.fetch("request").deep_symbolize_keys
      project = project_for(arguments.delete(:project_id))
      LayeredVerification::Audits::Request.call(**arguments, project:, user: current_user).then { |run| serialize(run) }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)

    def preview(project:, arguments:, plan:)
      obligations = project.layered_verification_obligations.where(id: arguments.fetch(:obligation_ids)).order(:id)
      raise ArgumentError, "audit scope requires at least one obligation" if obligations.empty?

      {
        request: arguments,
        resolved_scope: obligations.map { |obligation| { id: obligation.id, identity: obligation.external_identity, description: obligation.scope_description, approval_state: obligation.approval_state } },
        target_revision: arguments.fetch(:target_revision), budget: arguments.fetch(:budget),
        selected_checks: plan.selected_checks.map(&:to_h), omissions: plan.omissions, residual_gaps: plan.residual_gaps
      }
    end

    def serialize(run)
      { agent_run_id: run.id, status: run.status, preview: run.external_metadata.fetch("layered_verification_audit") }
    end
  end
end
