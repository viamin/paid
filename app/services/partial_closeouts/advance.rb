# frozen_string_literal: true

module PartialCloseouts
  # Schedules the one bounded recovery audit that a merged-partial guard would
  # otherwise require an operator to request manually. A source-retained gap
  # may instead take one revision-bound implementation continuation when the
  # project explicitly delegates the bounded technical choice. All execution
  # authority remains in the existing project gate and continuation service.
  # @spec PARTIAL-CLOSEOUT-024 PARTIAL-CLOSEOUT-057
  class Advance
    Result = Data.define(:agent_run, :code) do
      def scheduled? = agent_run.present?
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, assessment:)
      @agent_run = agent_run
      @assessment = assessment.to_h.deep_stringify_keys
    end

    def call
      return record(Result.new(agent_run: nil, code: :source_run_in_flight)) unless agent_run.finished?
      return record(Result.new(agent_run: nil, code: :automation_disabled)) unless project_gate_open?

      return record(delegated_implementation) if source_retained_agent_gap?
      return record(Result.new(agent_run: nil, code: :remaining_work)) if gaps.present?

      result = Issues::RequestAcceptanceAudit.call(
        issue: agent_run.issue,
        actor: agent_run.project.effective_owner,
        origin: :automatic
      )
      record(Result.new(agent_run: result.agent_run, code: result.code))
    end

    private

    attr_reader :agent_run, :assessment

    def gaps = Array(assessment["gaps"])

    def source_retained_agent_gap?
      gaps.one? && gaps.sole["kind"] == "agent" && gaps.sole["retain_on_source"] == true
    end

    def delegated_implementation
      gap = gaps.sole
      return Result.new(agent_run: nil, code: :human_decision_required) unless revisions_current?

      identity = Digest::SHA256.hexdigest({ source_revision: assessment["source_revision"], intent_revision: assessment["intent_revision"], gap: gap }.to_json)
      return Result.new(agent_run: nil, code: :unchanged_gap) if previously_continued?(identity)

      policy = Automation::EffectivePolicy.call(
        project: agent_run.project, phase: Automation::Phases::CODING, work_item: agent_run.issue,
        trigger: :automatic, delegated_action: "bounded_implementation_choice"
      )
      return Result.new(agent_run: nil, code: :human_decision_required) if policy.blocked?

      decision = ProjectDelegation::ActionPlan.call(
        project: agent_run.project, work_item: agent_run.issue, actor: agent_run.project.effective_owner,
        action: "bounded_implementation_choice", evidence: decision_evidence(gap)
      )
      return Result.new(agent_run: nil, code: :human_decision_required) if decision.blocked?

      result = Issues::RequestContinuation.call(
        issue: agent_run.issue, actor: agent_run.project.effective_owner, origin: :automatic,
        reason: "Complete the remaining accepted criterion: #{gap.fetch("criterion")}. #{gap["body"].to_s.strip}",
        evidence_context: { "partial_closeout_gap_identity" => identity, "remaining_work" => gap,
          "prior_closeout_evidence" => prior_closeout_evidence,
          "technical_choice" => { "selected_option" => "implement the focused source-retained gap",
            "audit_event_id" => decision.audit_event.id, "effective_policy" => policy.to_h } }
      )
      Result.new(agent_run: result.agent_run, code: result.code)
    end

    def decision_evidence(gap)
      current = current_assessment
      {
        "intent_revision" => assessment["intent_revision"] || PartialCloseouts::Assessment.intent_revision_for(agent_run.issue),
        "acceptance_revision" => Automation::DelegatedActionAdmission.acceptance_revision_for(current),
        "evidence_revision" => assessment["source_revision"] || current.current_source_revision,
        "policy_signature" => ProjectDelegation::Posture.resolve(agent_run.project).policy_signature,
        "lineage" => Automation::DelegatedActionAdmission.lineage_issue_ids(agent_run.issue),
        "alternatives" => [ "ask for a new product decision", "implement the focused source-retained gap" ],
        "selected_option" => "implement the focused source-retained gap",
        "rationale" => "The current assessment confines the remaining work to #{gap.fetch("criterion")}.",
        "tests" => [ "fresh acceptance audit" ],
        "review_evidence" => [ assessment["source_revision"], assessment["intent_revision"] ].compact
      }
    end

    def previously_continued?(identity)
      IssueContinuationRequest.where(issue: agent_run.issue).where("evidence->>'partial_closeout_gap_identity' = ?", identity).exists?
    end

    def revisions_current?
      assessment["source_revision"] == current_assessment.current_source_revision &&
        assessment["intent_revision"] == PartialCloseouts::Assessment.intent_revision_for(agent_run.issue)
    end

    def current_assessment
      @current_assessment ||= PartialCloseouts::Assessment.call(agent_run.issue)
    end

    def prior_closeout_evidence
      { "agent_run_id" => agent_run.id, "pull_request_number" => agent_run.pull_request_number,
        "pull_request_url" => agent_run.pull_request_url, "result_commit_sha" => agent_run.result_commit_sha }.compact
    end

    def project_gate_open?
      Issues::AutoPickProjectGate.call(agent_run.project)
    end

    def record(result)
      agent_run.update!(
        reconciliation: agent_run.reconciliation.merge(
          "advance" => {
            "action" => source_retained_agent_gap? ? "delegated_implementation_continuation" : "fresh_acceptance_audit",
            "outcome" => result.scheduled? ? "scheduled" : "waiting",
            "code" => result.code&.to_s,
            "inbox_decision_avoided" => source_retained_agent_gap? &&
              (result.scheduled? || agent_run.reconciliation.dig("advance", "inbox_decision_avoided") == true),
            "continuation_request_id" => result.agent_run&.continuation_request_id,
            "completion_outcome" => result.scheduled? ? "continuation_queued" : result.code&.to_s,
            "at" => Time.current.iso8601
          }.compact
        )
      )
      result
    end
  end
end
