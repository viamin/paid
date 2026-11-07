# frozen_string_literal: true

module Inbox
  # @spec INBOX-DECISION-BRIEF-001
  # Derives the concise decision brief every Inbox surface opens with: the
  # goal behind the work, what changed, the exact decision, Paid's grounded
  # recommendation when the structured state supports one, what happens after
  # acting, and what work is waiting (#4864). Pure projection over the entry's
  # current structured state — no render-time LLM call participates, and
  # stale or missing evidence is disclosed rather than asserted.
  #
  # Exceeds the ~100-line class target deliberately, mirroring
  # `Api::V1::InboxEntrySerializer`: one small branch per Inbox::Queue::KINDS
  # kind keeps each lane's copy readable next to its siblings, and splitting
  # them into per-kind classes would scatter the shared contract.
  class DecisionBrief
    Action = Struct.new(:label, :url, :external, keyword_init: true)
    Brief = Struct.new(:goal, :changed, :decision, :impact, :recommendation, :rationale,
      :after_action, :question, :unknowns, :evidence, :primary_action, :last_decision,
      keyword_init: true) do
      def to_h
        super.merge(unknowns: unknowns || [], evidence: evidence || [],
          primary_action: primary_action&.to_h)
      end
    end

    def self.call(entry:, detail: false)
      new(entry, detail:).call
    end

    # The list-safe subset shared by list rows and the API list payload.
    # Deliberately free of the detail-only reads (`last_decision`,
    # manual-review provenance, acceptance assessment).
    # @spec INBOX-DECISION-BRIEF-002
    def self.list_payload(entry)
      brief = call(entry:)
      { decision: brief.decision, impact: brief.impact, question: brief.question }.compact
    end

    def initialize(entry, detail: false)
      @entry = entry
      @detail = detail
    end

    def call
      fields = send("#{kind_underscored}_fields") || {}
      fields = base_fields.merge(fields)
      fields[:last_decision] = last_decision if detail?
      Brief.new(defaults.merge(fields.compact))
    end

    private

    attr_reader :entry
    delegate :kind, :project, :issue, :record, :questions, :tasks, :summary_text,
      :title_text, :action_url, :guidance, :closeout_status, to: :entry

    def detail? = @detail

    def kind_underscored = kind.tr(".", "_")

    def defaults
      { unknowns: [], evidence: [] }
    end

    # Shared fallbacks: the goal is the work item's agreed intent; the impact
    # names the waiting work in the operator's vocabulary.
    def base_fields
      {
        goal: goal_text,
        changed: summary_text.presence,
        decision: nil,
        impact: impact_text,
        after_action: nil
      }
    end

    def goal_text
      issue&.title || record.try(:title).presence || project&.full_name
    end

    def impact_text
      return "Work on #{ref} is paused." if ref

      "This project's work is waiting."
    end

    def ref
      return unless project && issue

      "#{project.full_name}##{issue.github_number}"
    end

    # --- Per-kind field derivation. Each branch reads only state the entry
    # --- already carries (or bounded detail-only reads, marked below).

    def clarifying_questions_fields
      first = questions.first
      question = first && ClarifyingQuestions::QuestionPayload.submission_text(first).presence
      {
        changed: "Paid paused work to ask #{pluralized_questions}.",
        decision: "Answer #{pluralized_questions}.",
        question:,
        after_action: "Your answers post to GitHub and work resumes on the next run.",
        evidence: questions.map { |item| "Question: #{ClarifyingQuestions::QuestionPayload.submission_text(item)}" }
      }
    end

    def pluralized_questions
      "#{questions.size} clarifying question#{'s' if questions.size != 1}"
    end

    def plan_review_fields
      {
        changed: "Paid proposed a plan with #{tasks.size} task#{'s' if tasks.size != 1}.",
        decision: "Approve the plan, or reject or revise it.",
        question: "Do the proposed tasks deliver #{goal_text.to_s.truncate(80)}?",
        after_action: "Approving starts implementation; rejecting returns the plan for revision.",
        impact: "Implementation cannot start until the plan is reviewed."
      }
    end

    def merge_approval_fields
      instruction = guidance&.dig(:instruction).to_s.presence
      stale = guidance&.dig(:stale_approval)
      unknowns = []
      unknowns << "The recorded approval is stale for the current revision, so it is not accepted as certainty." if stale
      {
        changed: guidance&.dig(:heading).presence || summary_text,
        decision: "Decide whether this pull request may merge.",
        recommendation: instruction,
        rationale: "Paid derives this from the recorded merge assessment.",
        unknowns:,
        after_action: "Paid re-checks the pull request on its next scan.",
        impact: "The pull request stays open until the decision is recorded."
      }
    end

    def action_required_fields
      recommendation = record.try(:metadata).to_h["recommended_action"].presence
      {
        changed: summary_text.presence || record.try(:description).presence,
        decision: title_text.presence || "Resolve the blocking condition.",
        recommendation:,
        rationale: recommendation ? "Acting on it unblocks the paused work." : nil,
        after_action: "Automatic work resumes once the condition is cleared.",
        impact: "Automatic work on #{project&.full_name} is blocked.",
        evidence: tasks.map { |step| "Remediation step: #{step}" },
        primary_action: primary_action_for(label: "Open linked action")
      }
    end

    def escalated_pr_fields
      awaiting = record.try(:reason) == Issue::PR_ESCALATION_REASON_AWAITING_APPROVAL
      {
        changed: summary_text.presence || "Paid stopped this pull request.",
        decision: awaiting ? "Re-approve the pull request on GitHub." : "Unblock the stopped pull request.",
        recommendation: awaiting ? "Review the changes and re-approve on GitHub." : "Unblock the pull request to resume automatic work.",
        rationale: "Paid derives this from the recorded stop reason.",
        after_action: "Paid resumes the delivery pipeline after the unblock.",
        impact: "The pull request and its issue stay paused.",
        evidence: record.try(:counters).to_a.map { |counter| "#{counter.name.to_s.humanize}: #{counter.value} of #{counter.limit}" }
      }
    end

    def manual_review_fields
      fields = {
        changed: summary_text.presence || "Paid stopped working this issue.",
        decision: "Review why Paid stopped and choose how to resume.",
        after_action: "The resume path you pick controls what Paid does next.",
        impact: "Work on #{ref} stays paused."
      }
      return fields unless detail?

      recovery = entry.manual_review_recovery
      case
      when recovery&.reopen_review?
        fields.merge(decision: "Record whether the reopened issue should continue.",
          recommendation: "Confirm the remaining scope against the current revision.",
          rationale: "The issue was reopened, so the earlier closure decision no longer applies.")
      when recovery&.dependency?
        fields.merge(decision: "Wait for the dependency or change its declaration.",
          question: "Is the dependency still required for this work?",
          unknowns: [ "The hold cannot be waived while the dependency is unresolved." ])
      when recovery&.authorize_new_remediation?
        fields.merge(decision: "Decide whether to authorize one more remediation run.",
          recommendation: "Authorize a new run only if the scanner evidence justifies another fix attempt.",
          rationale: "The scanner confirmed the finding recurred after the merged fix.")
      when recovery&.scanner?
        fields.merge(decision: "No action needed yet.",
          recommendation: "Wait for the next scanner verification.",
          rationale: "Verification is pending, not failed.")
      when questions.any?
        fields.merge(question: ClarifyingQuestions::QuestionPayload.submission_text(questions.first).presence)
      when recovery&.unknown?
        fields.merge(unknowns: [ "The provenance of this hold is unknown, so no automatic recovery is offered." ],
          question: "Should this work continue?")
      else
        fields
      end
    end

    def intent_conformance_fields
      verdict = record.try(:verdict)
      unknowns = []
      unknowns << "No conformance verdict is recorded, so drift cannot be ruled out." unless verdict
      {
        changed: record.try(:summary).presence || "The implementation may have drifted from the approved intent.",
        decision: "Decide whether the change matches the approved intent.",
        recommendation: verdict.present? ? "Review the cited claims and accept or revert the drift." : nil,
        rationale: verdict&.respond_to?(:reasoning_summary) ? verdict.reasoning_summary.presence : nil,
        after_action: "Your decision is recorded as the latest agreed intent.",
        unknowns:
      }
    end

    def feature_decision_fields
      fields = {
        changed: summary_text.presence,
        decision: "Approve the feature brief or record the decisions it is waiting on.",
        after_action: "Approving releases the feature's work for delivery.",
        impact: "The feature's work items stay gated."
      }
      return fields unless detail?

      actions = Inbox::FeatureDecisionReadiness.call(feature_intent: record).human_actions
      fields.merge(recommendation: actions.first&.message.presence)
    end

    def retry_limited_fields
      push_blocked = issue.try(:push_permission_abandoned?)
      returns = issue.try(:runner_retry_abandonment_count).to_i - 1
      {
        changed: summary_text.presence || "Paid stopped retrying this work.",
        decision: push_blocked ? "Restore push access, then re-enable the work." : "Investigate the failure, then re-enable the work.",
        recommendation: "Re-enable only after the cause is fixed.",
        after_action: "Paid resumes scheduling the work on its next pass.",
        impact: "Paid stopped after #{[ returns, 0 ].max} return#{'s' if returns != 1}."
      }
    end

    def change_intent_draft_fields
      requested_changes = record.try(:requested_changes?)
      {
        goal: record.try(:intent).presence || goal_text,
        changed: requested_changes ? "Paid recorded your requested changes." : "Paid drafted an intent record for this project.",
        decision: requested_changes ? "Review the updated draft." : "Approve the drafted intent or request changes.",
        after_action: "Approved intent becomes the agreed baseline for future work."
      }
    end

    def partial_closeout_fields
      status = closeout_status
      merged = Array(status.try(:evidence)&.merged_prs)
      changed = if merged.any?
        "A pull request was merged (##{merged.map { |pr| pr.respond_to?(:number) ? pr.number : pr }.join(', #')}) but the work is not finished."
      else
        "Paid stopped before finishing this work."
      end
      prerequisites = Array(status.try(:unresolved_prerequisites))
      fields = {
        changed:,
        decision: "Decide how the remaining scope should finish.",
        after_action: "The path you pick decides whether Paid continues, closes, or waits.",
        impact: "#{ref} stays out of automatic scheduling.",
        evidence: prerequisite_evidence(prerequisites, merged)
      }
      return fields unless detail?

      merge_partial_closeout_assessment(fields)
    end

    def prerequisite_evidence(prerequisites, merged)
      evidence = prerequisites.map { |prerequisite| "Waiting on prerequisite: #{prerequisite}" }
      evidence += merged.map { |pr| "Merged pull request ##{pr.respond_to?(:number) ? pr.number : pr}" }
      evidence
    end

    # Detail-only bounded read, the same assessment the pane renders.
    def merge_partial_closeout_assessment(fields)
      return fields unless issue

      assessment = PartialCloseouts::Assessment.call(issue)
      next_action = assessment.next_action.to_h["explanation"].presence
      if assessment.stale?
        fields.merge(recommendation: nil,
          unknowns: [ "The recorded acceptance assessment is stale, so no recommendation is grounded in it." ],
          question: "What should happen to the remaining scope?")
      else
        fields.merge(recommendation: next_action,
          rationale: next_action ? "Derived from the recorded acceptance assessment." : nil,
          question: next_action ? nil : "What should happen to the remaining scope?")
      end
    end

    def test_review_pending_fields
      {
        changed: "Paid wrote the red-phase tests and is waiting for your verdict.",
        decision: "Review the proposed tests and give a verdict.",
        question: "Do the tests capture the behavior you expect?",
        after_action: "A verdict releases implementation; a rejection restarts the red phase.",
        impact: "Implementation cannot start until the test verdict."
      }
    end

    def project_setup_pending_fields
      {
        goal: "Finish setting up #{project&.full_name}.",
        decision: "Resolve #{tasks.size} setup prerequisite#{'s' if tasks.size != 1}.",
        recommendation: tasks.first.presence,
        after_action: "Paid can schedule work once setup is complete.",
        impact: "Paid cannot run work on this project yet.",
        primary_action: primary_action_for(label: "Open project settings")
      }
    end

    def traceability_gap_fields
      unverifiable = record.try(:unverifiable?)
      {
        changed: summary_text.presence,
        decision: unverifiable ? "Restore coverage access and recheck." : "Record an explicit owner or disposition.",
        recommendation: unverifiable ? "Restore coverage access and recheck." : "Record an explicit owner or disposition.",
        rationale: "Derived from the recorded reconciliation finding.",
        after_action: "The finding clears once the artifact is reconciled."
      }
    end

    def layered_verification_finding_fields
      question = record.try(:decision).to_h["question"].presence
      {
        decision: question || "Record a decision on the verification finding.",
        question:,
        after_action: "Your decision is recorded; no repair is started automatically."
      }
    end

    def dependency_cycle_fields
      held = Array(record.try(:downstream_issues)).size
      {
        goal: "Keep #{project&.full_name} schedulable.",
        changed: "Paid detected a dependency cycle.",
        decision: "Break the cycle by removing or correcting one declaration.",
        recommendation: "Remove the obsolete declaration, or record why the cycle is intentional.",
        after_action: "Scheduling resumes once the cycle is broken.",
        impact: "#{held} downstream issue#{'s' if held != 1} remain held."
      }
    end

    def primary_action_for(label:)
      return unless action_url.present? && action_url != Rails.application.routes.url_helpers.inbox_entry_path(entry)

      Action.new(label:, url: action_url, external: action_url.start_with?("http"))
    end

    # Detail-only: the most recent agreed decision from the persisted
    # timeline (or lane state where the lane records it directly).
    def last_decision
      lane_decision || history_decision
    end

    def lane_decision
      decision = record.try(:latest_decision)
      return unless decision.respond_to?(:action) && decision.action.present?

      "#{decision.action.humanize}: #{decision.reason.presence || 'no reason recorded'}"
    end

    def history_decision
      subject_key = Inbox::ActionHistory.subject_key_for(entry)
      return unless subject_key

      event = InboxHistoryEvent.for_subject(account: project.account, subject_key:).newest_first.first
      return unless event

      "#{event.metadata['action'].presence || event.event_key.humanize} by #{event.actor_label}, #{I18n.l(event.occurred_at.to_date, format: :long)}"
    end
  end
end
