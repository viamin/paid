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
        request&.issue_id == issue&.id && request.evidence["continuation_mode"] == "acceptance_audit"
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
      snapshot.present? && snapshot["assessed_at"] == assessment.assessed_at &&
        assessment.closeout_state == "accepted_awaiting_github_closure" &&
        PartialCloseouts::SourceClosureDisposition.call(issue:, assessment: assessment.assessment)["disposition"] ==
          PartialCloseouts::SourceClosureDisposition::CLOSE
    end

    def assessment = PartialCloseouts::Assessment.call(issue)

    def rationale
      evidence = Issues::CloseoutEvidence.call(issue)
      links = evidence.merged_prs.first(5).map(&:url).compact
      links << "#{evidence.merged_prs.size - 5} more merged PRs" if evidence.merged_prs.size > 5
      links << "no-code declaration #{evidence.no_code_required_at.iso8601}" if evidence.no_code_required_at
      "Acceptance audit run ##{agent_run.id} accepted all #{assessment.criteria.size} criteria for " \
        "#{issue.project.full_name}##{issue.github_number}; evidence: #{links.join(', ')}."
    end

    def audit_metadata
      posture = ProjectDelegation::Posture.resolve(issue.project)
      { "initiator" => "delegated_acceptance_audit", "agent_run_id" => agent_run.id,
        "continuation_request_id" => request.id, "policy_revision" => posture.revision,
        "policy_signature" => request.evidence["closeout_policy_signature"],
        "selected_by_id" => posture.selected_by_id }
    end

    def record_attempt(result)
      Audit::RecordEvent.call(action: "issue.auto_closeout_attempted", subject: issue,
        metadata: audit_metadata.merge("result" => result.success? ? "closed" : result.code.to_s,
          "evidence_digest" => Issues::CloseoutEvidence.call(issue).digest))
    end
  end
end
