# frozen_string_literal: true

module Inbox
  class MergeApproval
    APPROVAL_SIGNALS = %w[owner_approved reviews_fresh].freeze
    STALL_WINDOW = 24.hours
    FAILED_CREATE_PR_WINDOW = 24.hours
    ACTIVE_WORKFLOW_STATUSES = AgentRun::UNFINISHED_STATUSES
    TERMINAL_CREATE_PR_STATUSES = AgentRun::TERMINAL_FAILURE_STATUSES

    def self.call(issue, phase_authorized: nil)
      new(issue, phase_authorized:).call
    end

    # Narrows to rows that could plausibly need an operator before falling back
    # to Ruby for the full `call` signal check (`APPROVAL_SIGNALS`), so
    # counting/listing stays a bounded scan instead of one Issue
    # instantiation per open, ready PR on the account. Shared by
    # `Inbox::Count` and `Inbox::Availability` so the candidate definition
    # can't drift between the badge, the filters dialog, and the queue.
    # @spec AUTO-MERGE-009 INBOX-FOUNDATION-008 INBOX-FOUNDATION-011 INBOX-FOUNDATION-012 INBOX-FOUNDATION-013 OPERATOR-INBOX-002K LABEL-CONTROL-004
    def self.candidates(project_ids)
      Issue
        .joins(:project)
        .includes(:project)
        .where(
          project_id: project_ids,
          is_pull_request: true,
          github_state: "open",
          merge_permission_rejected_at: nil
        )
        .where(
          candidate_conditions,
          hold_label: [ Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL ].to_json,
          stalled_since: STALL_WINDOW.ago,
          failed_run_since: FAILED_CREATE_PR_WINDOW.ago,
          terminal_statuses: TERMINAL_CREATE_PR_STATUSES,
          active_statuses: ACTIVE_WORKFLOW_STATUSES
        )
    end

    def self.candidate_conditions
      "(projects.label_integration_mode <> 'ignored' AND issues.labels @> :hold_label::jsonb) OR " \
          "(projects.label_integration_mode = 'ignored' AND issues.hold_for_review = TRUE) OR (" \
          "issues.auto_merge_evaluated_at IS NOT NULL AND " \
          "issues.auto_merge_blockers IS NOT NULL AND (" \
          "projects.auto_merge_mode = 'off' OR projects.owner_reviewer_login IS NOT NULL)) OR (" \
          "projects.pr_target = 'own_repo' AND (issues.github_updated_at <= :stalled_since OR EXISTS (" \
          "SELECT 1 FROM agent_runs WHERE agent_runs.project_id = issues.project_id " \
          "AND agent_runs.goal = 'create_pr' AND agent_runs.status IN (:terminal_statuses) " \
          "AND agent_runs.updated_at >= :failed_run_since)) AND NOT EXISTS (" \
          "SELECT 1 FROM agent_runs WHERE agent_runs.project_id = issues.project_id " \
          "AND (agent_runs.source_pull_request_number = issues.github_number OR " \
          "agent_runs.pull_request_number = issues.github_number OR agent_runs.issue_id = issues.id) " \
          "AND agent_runs.status IN (:active_statuses)))"
    end
    private_class_method :candidate_conditions

    def initialize(issue, phase_authorized: nil)
      @issue = issue
      @phase_authorized = phase_authorized
    end

    def call
      return unless candidate?

      Snapshot.new(issue:, blockers: failed_blockers, phase_authorized:)
    end

    class Snapshot
      attr_reader :blockers, :issue, :phase_authorized

      def initialize(issue:, blockers:, phase_authorized: nil)
        @issue = issue
        @blockers = blockers
        @phase_authorized = phase_authorized
      end

      def summary
        return "Human review requested before merging" if held_for_review?
        return "Paid automation stalled before PR reconciliation" if stalled?
        return "Approval is stale for the current revision" if stale_approval?
        return "Human review required before manual merge" if manual_merge? && approval_required?
        return "Manual merge decision required" if manual_merge?

        "Waiting for owner approval"
      end

      def waiting_since
        issue.awaiting_approval_since || issue.github_updated_at
      end

      # A presentation contract derived from the assessment state, rather than
      # from its human-readable summary. The web, API, and chat surfaces share
      # it so a project with per-PR auto-merge activation cannot receive the
      # manual-merge instructions (or vice versa).
      # @spec OPERATOR-INBOX-002K
      def guidance
        {
          heading: guidance_heading,
          instruction: guidance_instruction,
          automatic_merge_active: automatic_merge_active?,
          stale_approval: stale_approval?,
          approval_evidence: approval_evidence,
          blockers: display_blockers
        }
      end

      private

      def stalled?
        MergeApproval.stalled?(issue)
      end

      def stale_approval?
        blockers.any? { |blocker| blocker["signal"] == "reviews_fresh" }
      end

      def held_for_review?
        issue.held_for_review?
      end

      def manual_merge?
        !automatic_merge_active?
      end

      def approval_required?
        blockers.any? { |blocker| blocker["signal"] == "owner_approved" }
      end

      def automatic_merge_active?
        Automation::FeatureActivation.human_pull_request_auto_merge_enabled?(
          project: issue.project,
          pull_request: issue,
          phase_authorized: phase_authorized
        )
      end

      def guidance_heading
        return "Human review is on hold" if held_for_review?
        return "Paid automation stopped" if stalled?
        return "Approval is stale for the current revision" if stale_approval?
        return "Manual merge decision on GitHub" if manual_merge?

        "Review on GitHub"
      end

      def guidance_instruction
        return held_review_instruction if held_for_review?
        return stalled_instruction if stalled?
        return stale_approval_instruction if stale_approval?
        return "Review the current changes and make the manual merge decision on GitHub. Paid will not merge this pull request automatically." if manual_merge?

        "Approve the current revision on GitHub. Paid will reevaluate it on a later scan, subject to all remaining checks and policy."
      end

      def stalled_instruction
        "Paid stopped progressing this pull request before it reconciled its current state. Review the current changes and start a manual run or resolve the automation failure; this entry does not authorize a merge."
      end

      def held_review_instruction
        return "Review the current changes and make the manual merge decision on GitHub. Paid will not merge this pull request automatically." if manual_merge?

        "Review the current changes and remove the hold when automatic merging may resume."
      end

      def stale_approval_instruction
        explanation = "Commits were added after the recorded approval, so Paid treats that approval as stale even if GitHub still shows Approved."
        return "#{explanation} Review the current changes and make the manual merge decision on GitHub. Re-approval alone will not cause Paid to merge it." if manual_merge?

        "#{explanation} Review and approve the current revision on GitHub; Paid will reevaluate it on a later scan, subject to all remaining checks and policy."
      end

      def display_blockers
        blockers.present? ? blockers.map { |blocker| display_blocker(blocker) } : [ synthetic_blocker ]
      end

      def synthetic_blocker
        if held_for_review?
          {
            "signal" => "human_review_hold",
            "status" => "failed",
            "sanitized_message" => "Human review was explicitly requested.",
            "next_action" => held_review_instruction
          }
        else
          {
            "signal" => "automation_stalled",
            "status" => "failed",
            "sanitized_message" => "Paid automation stopped before reconciling this pull request.",
            "next_action" => stalled_instruction
          }
        end
      end

      def display_blocker(blocker)
        blocker.merge("next_action" => blocker_next_action(blocker))
      end

      def blocker_next_action(blocker)
        return guidance_instruction if blocker["signal"].in?(APPROVAL_SIGNALS)

        blocker["next_action"]
      end

      # @spec OPERATOR-INBOX-002K
      def approval_evidence
        evidence = stale_approval_blocker&.fetch("approval_evidence", {})&.deep_stringify_keys || {}
        stale_entries = approval_evidence_stale_entries(evidence)
        return {} if stale_entries.empty? && issue.auto_merge_evaluated_at.blank?

        current_revision = stale_entries.first&.fetch("current_revision") ||
          evidence["current_revision"] ||
          issue.last_scanned_head_sha
        assessed_at = issue.auto_merge_evaluated_at&.iso8601

        enriched = stale_entries.map do |entry|
          approved_revision = entry["approved_revision"]
          entry.merge(
            "assessed_at" => assessed_at,
            "comparison_url" => comparison_url(approved_revision, current_revision)
          ).compact
        end
        return {} if enriched.empty?

        { "stale_approvals" => enriched, "current_revision" => current_revision }.compact
      end

      # Returns the per-approvals evidence in the canonical array shape,
      # converting snapshots written by the legacy single-approval schema
      # (the owner's evidence only — see #4519) into a single-entry array
      # so the view never has to branch on the snapshot shape.
      def approval_evidence_stale_entries(evidence)
        return Array(evidence["stale_approvals"]) if evidence["stale_approvals"].present?

        legacy = {
          "approved_revision" => evidence["approved_revision"],
          "approved_at" => evidence["approved_at"],
          "current_revision" => evidence["current_revision"]
        }.compact
        legacy.empty? ? [] : [ legacy ]
      end

      def stale_approval_blocker
        blockers.find { |blocker| blocker["signal"] == "reviews_fresh" }
      end

      def comparison_url(approved_revision, current_revision)
        return if approved_revision.blank? || current_revision.blank?

        "#{issue.project.github_url}/compare/#{approved_revision}...#{current_revision}"
      end
    end

    private

    attr_reader :issue, :phase_authorized

    def candidate?
      # @spec AUTO-MERGE-009 INBOX-FOUNDATION-008 INBOX-FOUNDATION-011 INBOX-FOUNDATION-012 INBOX-FOUNDATION-013 OPERATOR-INBOX-002K LABEL-CONTROL-004
      return false unless reviewable_pr?
      return true if held_for_review?
      return true if stalled?
      return false if manual_merge? && automatic_merge_active?

      manual_merge? ? manual_action_required? : approval_only_blockers?
    end

    def reviewable_pr?
      issue.is_pull_request? &&
        issue.github_state == "open" &&
        !issue.merge_permission_rejected? &&
        (issue.ready_phase? || held_for_review? || stalled?) &&
        (manual_merge? || automatic_merge_configured? || held_for_review? || stalled?)
    end

    # @spec INBOX-FOUNDATION-013
    def self.stalled?(issue)
      return false unless issue.is_pull_request? && issue.github_state == "open"
      return false unless issue.project.pr_target == "own_repo"
      return false if issue.auto_merge_evaluated_at.present? || issue.auto_merge_blockers.present?
      return false unless automation_scope?(issue)
      return false if active_workflow?(issue)
      return false unless old_or_failed_create_run?(issue)

      missing_reconciliation_marker?(issue)
    end

    def self.automation_scope?(issue)
      issue.project.auto_add_labels_enabled? ||
        issue.project.auto_merge_mode != "off" ||
        issue.has_label?(issue.project.automation_label_name)
    end

    def self.active_workflow?(issue)
      AgentRun.where(project_id: issue.project_id, status: ACTIVE_WORKFLOW_STATUSES)
        .where(
          "source_pull_request_number = :number OR pull_request_number = :number OR issue_id = :issue_id",
          number: issue.github_number,
          issue_id: issue.id
        ).exists?
    end

    def self.old_or_failed_create_run?(issue)
      return true if issue.github_updated_at.present? && issue.github_updated_at <= STALL_WINDOW.ago

      AgentRun.where(
        project_id: issue.project_id,
        goal: "create_pr",
        status: TERMINAL_CREATE_PR_STATUSES
      ).where("updated_at >= ?", FAILED_CREATE_PR_WINDOW.ago).exists?
    end

    def self.missing_reconciliation_marker?(issue)
      return false unless issue.project.auto_add_labels_enabled?
      return false if issue.has_label?(issue.project.generated_label_name)

      issue.pr_review_phase.in?(%w[draft restarted])
    end

    def stalled?
      self.class.stalled?(issue)
    end

    def held_for_review?
      issue.held_for_review?
    end

    def approval_only_blockers?
      issue.project.owner_reviewer_login.present? &&
        blockers_snapshot.present? &&
        failed_blockers.any? &&
        not_evaluated_blockers.empty? &&
        failed_blockers.all? { |blocker| APPROVAL_SIGNALS.include?(blocker["signal"]) }
    end

    def manual_merge?
      issue.project.auto_merge_mode == "off"
    end

    def automatic_merge_active?
      Automation::FeatureActivation.human_pull_request_auto_merge_enabled?(
        project: issue.project,
        pull_request: issue,
        phase_authorized: phase_authorized
      )
    end

    # Candidacy is determined by the configured merge lane. Phase relevance
    # decides whether the resulting request is actionable or disabled.
    def automatic_merge_configured?
      Automation::FeatureActivation.human_pull_request_auto_merge_enabled?(
        project: issue.project,
        pull_request: issue,
        phase_authorized: true
      )
    end

    def manual_action_required?
      blockers_snapshot.present? &&
        not_evaluated_blockers.empty? &&
        failed_blockers.all? { |blocker| APPROVAL_SIGNALS.include?(blocker["signal"]) }
    end

    def blockers_snapshot
      return @blockers_snapshot if defined?(@blockers_snapshot)

      @blockers_snapshot =
        if issue.auto_merge_evaluated_at.present? && issue.auto_merge_blockers.is_a?(Hash)
          issue.auto_merge_blockers.deep_stringify_keys
        end
    end

    def failed_blockers
      blockers_snapshot&.fetch("failed", []) || []
    end

    def not_evaluated_blockers
      blockers_snapshot&.fetch("not_evaluated", []) || []
    end
  end
end
