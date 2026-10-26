# frozen_string_literal: true

module Tools
  # Requests a bounded layered-verification audit for a project.
  #
  # The project action, the project-scoped chat tool, and the MCP tool all
  # dispatch into this one class, so every surface resolves the scope,
  # checks the same authorization, and creates the same audit request. The
  # audit never repairs anything: it investigates and reports.
  #
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch

    def self.description
      "Request a bounded layered-verification audit of a project. The audit compares approved business " \
        "intent with the implementation, records what it checked and what it could not establish, and " \
        "surfaces actionable findings in the Inbox. It never changes code or intent."
    end

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? do |project|
        next false unless LayeredVerification::AuditAccess.feature_enabled?(project)

        policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    # A chat turn only sees this tool when the chat is scoped to a project
    # whose add-on is enabled and whose audit bar the user holds.
    def self.available_for_chat?(user:, session:)
      return false if user.blank?

      project = session&.project
      return false unless project
      return false unless LayeredVerification::AuditAccess.feature_enabled?(project)

      policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID. Optional when the chat is scoped to a project." },
          scope_description: { type: "string", description: "The bounded business slice to audit." },
          sources: {
            type: "array",
            items: { type: "string" },
            description: "Repository-relative paths of the sources and representations the audit reads."
          },
          target_revision: { type: "string", description: "The revision the audit is bound to. Defaults to the current head." },
          budget: { type: "object", description: "Bounded budget for the audit (max checks, tokens, duration)." },
          audit_id: { type: "integer", description: "An audit request that was already created, to dispatch." }
        },
        required: %w[scope_description sources]
      }
    end

    def perform(project_id: nil, scope_description: nil, sources: [], target_revision: nil, budget: {}, audit_id: nil,
      confirmed: false)
      if audit_id.present?
        raise ArgumentError, "confirm the audit request before dispatching it" unless confirmed

        return dispatch_existing(audit_id)
      end

      request = create_request(project_id:, scope_description:, sources:, target_revision:, budget:)
      return dispatch_request(request.audit) if confirmed

      draft_payload(request.audit)
    end

    # The human confirms the resolved scope before the run is dispatched.
    def resolve_confirmation(decision:, pending_result:)
      audit_id = pending_result["id"] || pending_result[:id]
      raise ArgumentError, "pending result must include an id" if audit_id.blank?

      audit = LayeredVerificationAudit.find_by(id: audit_id)
      raise ArgumentError, "the audit request no longer exists" unless audit

      case decision
      when :approve then dispatch_request(audit)
      when :deny then decline_request(audit)
      else raise ArgumentError, "decision must be approve or deny"
      end
    rescue Pundit::NotAuthorizedError => error
      raise UnauthorizedError, error.message
    end

    private

    def create_request(project_id:, scope_description:, sources:, target_revision:, budget:)
      LayeredVerification::Audits::Request.call(
        project: project_for(project_id: project_id),
        user: current_user,
        scope_description: scope_description,
        sources: Array(sources),
        target_revision: target_revision,
        budget: budget || {},
        trigger_type: trigger_type
      )
    end

    def draft_payload(audit)
      {
        id: audit.id,
        status: "draft",
        audit_id: audit.id,
        project_id: audit.project_id,
        resolved_scope: resolved_scope(audit)
      }
    end

    def dispatch_request(audit)
      run = LayeredVerification::Audits::Dispatch.call(audit:, user: current_user, trigger_type: trigger_type)
      {
        id: run.id,
        status: run.status,
        audit_id: audit.id,
        project_id: audit.project_id,
        resolved_scope: resolved_scope(audit)
      }
    end

    def dispatch_existing(audit_id)
      audit = LayeredVerificationAudit.find_by(id: audit_id)
      raise ArgumentError, "the audit request no longer exists" unless audit

      dispatch_request(audit)
    end

    def decline_request(audit)
      audit.update!(status: "cancelled", cancelled_at: Time.current, waiting_reason: "the audit request was declined")
      { id: audit.id, status: "cancelled", audit_id: audit.id, project_id: audit.project_id }
    end

    def resolved_scope(audit)
      {
        "scope_description" => audit.scope_description,
        "sources" => audit.sources,
        "target_revision" => audit.target_revision,
        "budget" => audit.budget,
        "plan" => audit.plan
      }
    end

    def trigger_type
      return "manual_mcp" if mcp
      return "manual_chat" if session

      "manual_ui"
    end

    def project_for(args = nil, project_id: nil)
      identifier = project_id || args&.dig(:project_id) || args&.dig("project_id")
      return session.project if identifier.blank? && session

      project = policy_scope(Project).find(identifier)
      unless LayeredVerification::AuditAccess.feature_enabled?(project)
        raise LayeredVerification::AuditAccess::FeatureDisabledError,
          "layered verification is not enabled for this project"
      end

      project
    end
  end
end
