# frozen_string_literal: true

module Issues
  # Executes only the closure decision delegated before the audit was queued.
  # The audit remains report-only; this post-run boundary owns GitHub mutation.
  # @spec PROJECT-DELEGATION-009
  class AutoResolveCloseout
    ACTION = "evidence_gated_issue_closure"
    POLICY_ACTION = "issue_closure"

    def self.call(...) = new(...).call

    def self.authority_signature(issue)
      project = issue.project
      posture = ProjectDelegation::Posture.resolve(project)
      return unless posture.bounded_delivery? && posture.enabled_action_classes.include?(ACTION)

      policy = Automation::EffectivePolicy.call(project:, phase: Automation::Phases::MERGE,
        work_item: issue, trigger: :automatic, delegated_action: POLICY_ACTION)
      return unless policy.permitted?

      Automation::DelegatedActionAdmission.posture_signature_for(project:, action: POLICY_ACTION)
    end

    def initialize(agent_run:, client: nil)
      @agent_run = agent_run
      @client = client
    end

    def call
      return :not_audit unless completed_audit?
      return :already_closed unless issue.github_state == "open"
      return :not_delegated unless current_authority?
      return :blocked unless current_acceptance? && Issues::CloseoutStatus.call(issue).blockers.empty?

      result = Issues::ResolveCloseout.call(issue:, actor: nil, reason: rationale,
        client:, authorization_metadata: audit_metadata,
        authorization_check: -> { current_authority? })
      record_attempt(result)
      result.success? ? :closed : result.code
    end

    private

    attr_reader :agent_run, :client

    def issue = agent_run.issue
    def request = agent_run.continuation_request

    def completed_audit?
      agent_run.status == "completed" && agent_run.goal == "analyze_issue" &&
        agent_run.project_id == issue&.project_id && request&.project_id == issue&.project_id &&
        request.issue_id == issue.id && request.status == "consumed" &&
        request.evidence["continuation_mode"] == "acceptance_audit"
    end

    def current_authority?
      issue.reload
      issue.project.reload
      captured = request.evidence["closeout_policy_signature"]
      captured.present? && captured == self.class.authority_signature(issue) &&
        request.evidence["intent_revision"] == PartialCloseouts::Assessment.intent_revision_for(issue) &&
        request.evidence["source_revision"] == assessment.current_source_revision
    end

    def current_acceptance?
      snapshot = agent_run.reconciliation.to_h["assessment"]
      snapshot.present? && snapshot == assessment.assessment &&
        assessment.closeout_state == "accepted_awaiting_github_closure" &&
        assessment.criteria.all? { |criterion| citation_for(criterion).present? } &&
        PartialCloseouts::SourceClosureDisposition.call(issue:, assessment: assessment.assessment)["disposition"] ==
          PartialCloseouts::SourceClosureDisposition::CLOSE
    end

    def assessment = PartialCloseouts::Assessment.call(issue)

    def rationale
      criteria = assessment.criteria.map do |criterion|
        citation = citation_for(criterion)
        reference = [ citation.fetch("label"), citation["url"].presence ].compact.join(" ")
        "#{criterion.fetch('criterion')}: #{reference}"
      end
      "Acceptance audit run ##{agent_run.id} accepted all #{criteria.size} criteria for " \
        "#{issue.project.full_name}##{issue.github_number}; evidence by criterion: #{criteria.join('; ')}."
    end

    def citation_for(criterion)
      return unless criterion["evidence"].is_a?(Array)

      criterion["evidence"].find { |citation| citation.is_a?(Hash) && citation["label"].present? }
    end

    def audit_metadata
      posture = ProjectDelegation::Posture.resolve(issue.project)
      { "initiator" => "delegated_acceptance_audit", "agent_run_id" => agent_run.id,
        "continuation_request_id" => request.id, "policy_revision" => posture.revision,
        "policy_signature" => request.evidence["closeout_policy_signature"],
        "selected_by_id" => posture.selected_by_id,
        "assessment_source_revision" => agent_run.reconciliation.dig("assessment", "source_revision"),
        "assessment_intent_revision" => agent_run.reconciliation.dig("assessment", "intent_revision"),
        "assessment_assessed_at" => agent_run.reconciliation.dig("assessment", "assessed_at") }
    end

    def record_attempt(result)
      Audit::RecordEvent.call(action: "issue.auto_closeout_attempted", subject: issue,
        metadata: audit_metadata.merge("result" => result.success? ? "closed" : result.code.to_s,
          "evidence_digest" => Issues::CloseoutEvidence.call(issue).digest))
    end
  end
end
