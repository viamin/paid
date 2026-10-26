# frozen_string_literal: true

# Routes a manual-review hold using durable state, rather than interpreting the
# free-form operator-facing reason.  The same classification is consumed by the
# Inbox and its commands so a button cannot clear a hold it does not understand.
module ManualReviews
  class Recovery
    Cause = Data.define(:key, :action, :message, :blocking_runs, :dependencies)

    REOPEN_VALIDATION_TAG = "reopen_review_validation"

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Cause.new(:reopen_review, :record_decision, "Review the closure and remaining scope before continuing.", active_runs, []) if issue.reopen_review_pending? && !reopen_validated?
      return Cause.new(:dependency, :wait, dependency_message, active_runs, blocking_dependencies) if blocking_dependencies.any?
      return Cause.new(:scanner_recurrence, :recover_scanner, "Review the scanner evidence and authorize remediation through its existing recovery flow.", active_runs, []) if scanner_recurrence?
      return Cause.new(:reopen_review, :resume_enhancement, "The reopen-intent decision is recorded; retry analysis to determine the remaining work.", active_runs, []) if issue.reopen_review_pending?
      return Cause.new(:enhancement, :resume_enhancement, "Retry issue analysis with the existing enhancement recovery.", active_runs, []) if enhancement_provenance?

      Cause.new(:unknown, :none, "This manual-review hold has no supported recovery provenance. Its recorded reason remains visible.", active_runs, [])
    end

    def record_reopen_validation!(actor:, reason:, revision:)
      issue.with_lock do
        issue.reload
        raise ArgumentError, "This issue is no longer awaiting reopen review." unless issue.reopen_review_pending?
        raise ArgumentError, "A reason is required." if reason.to_s.strip.blank?
        raise ArgumentError, "This issue changed; reload before deciding." unless revision == issue_revision
        return if reopen_validated?

        DecisionRecord.create!(
          project: issue.project,
          issue: issue,
          title: "Reopen intent validation for ##{issue.github_number}",
          summary: "An authorized operator reviewed the prior closure and remaining scope.",
          decision: reason.to_s.strip,
          context: { "issue_revision" => revision, "github_state" => issue.github_state }.to_json,
          status: "active",
          tags: [ REOPEN_VALIDATION_TAG ]
        )
        Audit::RecordEvent.call(action: "issue.reopen_review_validated", actor: actor, subject: issue,
          metadata: { issue_revision: revision })
      end
    end

    def issue_revision
      issue.github_updated_at.iso8601
    end

    private

    attr_reader :issue

    def reopen_validated?
      issue.decision_records.where("tags @> ?::jsonb", [ REOPEN_VALIDATION_TAG ].to_json).exists?
    end

    def blocking_dependencies
      @blocking_dependencies ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.to_a + issue.blocking_external_dependencies.to_a
    end

    def dependency_message
      refs = blocking_dependencies.filter_map do |dependency|
        dependency.respond_to?(:external_ref) ? dependency.external_ref : "##{dependency.github_number}"
      end
      "Wait for unresolved dependency #{refs.uniq.join(", ")}."
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE &&
        issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_provenance?
      issue.agent_runs.where(goal: "enhance_issue").exists? || issue.needs_input_questions.present? ||
        issue.manual_review_reason.to_s.start_with?(
          "Paid reached the configured limit of enhancement re-evaluation rounds.",
          "Round limit reached.",
          "Structured output failed validation.",
          "Paid could not validate the enhancement agent's structured output."
        )
    end

    def active_runs
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:id).to_a
    end
  end
end
