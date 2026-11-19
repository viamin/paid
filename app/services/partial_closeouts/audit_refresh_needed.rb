# frozen_string_literal: true

module PartialCloseouts
  # A queued audit may observe newer evidence than its admission authorized.
  # Preserve that report, then obtain a fresh bounded admission rather than
  # rewriting its captured authority or closing from the obsolete request.
  # @spec STAGED-CLOSEOUT-ADOPTION-015
  class AuditRefreshNeeded
    def self.call(issue:, assessment: Assessment.call(issue))
      return true if assessment.stale?
      return false unless assessment.closeout_state == "accepted_awaiting_github_closure"
      return false unless SourceClosureDisposition.call(issue:, assessment: assessment.assessment)["disposition"] == SourceClosureDisposition::CLOSE

      signature = Issues::AutoResolveCloseout.authority_signature(issue)
      return false if signature.blank?

      run = AgentRun.where(project: issue.project, issue:)
        .where("reconciliation ? 'assessment'").order(id: :desc).first
      return false unless run&.goal == "analyze_issue" && run.status == "completed" &&
        run.reconciliation["assessment"] == assessment.assessment
      request = run&.continuation_request
      return false unless request && request.project_id == issue.project_id && request.issue_id == issue.id && request.status == "consumed"

      evidence = request.evidence
      evidence["continuation_mode"] == "acceptance_audit" &&
        evidence["closeout_policy_signature"] == signature &&
        evidence["intent_revision"] == Assessment.intent_revision_for(issue) &&
        evidence["source_revision"].present? && evidence["source_revision"] != assessment.current_source_revision
    end
  end
end
