# frozen_string_literal: true

module QueueStalls
  # Recognises delivery handoffs that stopped progressing, using mechanical
  # conditions only — no semantic judgment, no LLM call, no repository
  # execution (#4619).
  #
  # Three conditions are recognised:
  #
  # - `unseeded_runnable` — the issue is in the project's canonical candidate
  #   scope and no queued or running run covers it, so the handoff from
  #   eligibility to the scheduler never happened.
  # - `stale_planning_hold` — the issue serves an unreleased confidence-driven
  #   feature link whose hold is recorded, and no run covers the issue.
  # - `unresolved_delivery` — a merged pull request is authoritatively linked
  #   back to the open issue, no run covers it, and no continuation is
  #   authorized, so the delivery was never handed to its next stage.
  #
  # @spec QUEUE-DIAG-004 @spec QUEUE-DIAG-011
  class Detector
    Candidate = Struct.new(:issue_id, :reason_code, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      return [] unless eligible_project?

      candidates = []
      candidates.concat(unseeded_candidates)
      candidates.concat(stale_planning_hold_candidates)
      candidates.concat(unresolved_delivery_candidates)
      candidates.uniq { |candidate| [ candidate.issue_id, candidate.reason_code ] }
    end

    private

    attr_reader :project

    # The auto-pick switch and the project gate are admission controls, not
    # diagnosis inputs: a project that does not admit automatic work has no
    # handoff to stall. A paused project is excluded for the same reason —
    # its queued runs are not dispatched, so seeding more work would only
    # add backlog nobody can start.
    def eligible_project?
      return false if project.paused?

      project.auto_pick_enabled? && Issues::AutoPickProjectGate.call(project)
    end

    def unseeded_candidates
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(project)
        .order(:github_number)
        .pluck(:id)
        .map { |issue_id| Candidate.new(issue_id:, reason_code: "unseeded_runnable") }
    end

    def stale_planning_hold_candidates
      links = FeatureIntentIssue
        .joins(:feature_intent)
        .where(feature_intents: { project_id: project.id, delivery_policy: "confidence_driven" })
        .where.not(release_state: "released")
        .includes(:feature_intent)
        .order(:id)
        .to_a

      issue_ids = links.reject { |link| link.planning_task? }.map(&:issue_id).uniq
      (issue_ids.to_set - covered_issue_ids).map do |issue_id|
        Candidate.new(issue_id:, reason_code: "stale_planning_hold")
      end
    end

    def unresolved_delivery_candidates
      issue_ids = merged_delivery_issue_ids - covered_issue_ids - open_continuation_issue_ids
      issue_ids.map { |issue_id| Candidate.new(issue_id:, reason_code: "unresolved_delivery") }
    end

    # Issues whose source issue received a merged pull request. The link is
    # the authoritative one (`parent_issue_id`), the same discipline
    # `Issues::CloseoutEvidence` uses.
    def merged_delivery_issue_ids
      Issue
        .where(project_id: project.id, is_pull_request: true, pr_review_phase: "merged")
        .where.not(parent_issue_id: nil)
        .distinct
        .pluck(:parent_issue_id)
        .to_set
    end

    def covered_issue_ids
      AgentRun
        .where(project_id: project.id, status: %w[queued running])
        .where.not(issue_id: nil)
        .pluck(:issue_id)
        .to_set
    end

    def open_continuation_issue_ids
      IssueContinuationRequest.open.where(project_id: project.id).pluck(:issue_id).to_set
    end
  end
end
