# frozen_string_literal: true

module Inbox
  class MergeApproval
    APPROVAL_SIGNALS = %w[owner_approved reviews_fresh].freeze
    STALL_CANDIDATE_WINDOW = 30.days
    STALL_GRACE_PERIOD = 10.minutes

    def self.call(issue, phase_authorized: nil)
      new(issue, phase_authorized:).call
    end

    # Narrows to rows that could plausibly need an operator before falling back
    # to Ruby for the full `call` signal check (`APPROVAL_SIGNALS`), so
    # counting/listing stays a bounded scan instead of one Issue
    # instantiation per open, ready PR on the account. Shared by
    # `Inbox::Count` and `Inbox::Availability` so the candidate definition
    # can't drift between the badge, the filters dialog, and the queue.
    # @spec AUTO-MERGE-009 INBOX-FOUNDATION-008 INBOX-FOUNDATION-011 OPERATOR-INBOX-002K LABEL-CONTROL-004
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
        .where(candidate_conditions)
    end

    def self.candidate_conditions
      Issue.sanitize_sql_array([
        "(projects.label_integration_mode <> 'ignored' AND issues.labels @> :hold_label::jsonb) OR " \
          "(projects.label_integration_mode = 'ignored' AND issues.hold_for_review = TRUE) OR (" \
          "issues.pr_review_phase = 'ready' AND " \
          "issues.auto_merge_evaluated_at IS NOT NULL AND " \
          "issues.auto_merge_blockers IS NOT NULL AND (" \
          "projects.auto_merge_mode = 'off' OR projects.owner_reviewer_login IS NOT NULL)) OR (" \
          "issues.github_updated_at >= :stall_cutoff AND projects.pr_target = 'own_repo' AND " \
          "projects.auto_add_labels_enabled = TRUE AND issues.pr_review_phase <> 'ready')",
        hold_label: [ Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL ].to_json,
        stall_cutoff: STALL_CANDIDATE_WINDOW.ago
      ])
    end
    private_class_method :candidate_conditions

    def initialize(issue, phase_authorized: nil)
      @issue = issue
      @phase_authorized = phase_authorized
    end

    def call
      return unless candidate?

      Snapshot.new(issue:, blockers: failed_blockers, phase_authorized:, stalled_run:)
    end

    class Snapshot
      attr_reader :blockers, :issue, :phase_authorized

      def initialize(issue:, blockers:, phase_authorized: nil, stalled_run: nil)
        @issue = issue
        @blockers = blockers
        @phase_authorized = phase_authorized
        @stalled_run = stalled_run
      end

      def summary
        return "Human review requested before merging" if held_for_review?
        return "Pull request automation stopped after #{run_status}" if stalled_run
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
        }.merge(stall_evidence)
      end

      private

      attr_reader :stalled_run

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
        return "Pull request automation stopped" if stalled_run
        return "Approval is stale for the current revision" if stale_approval?
        return "Manual merge decision on GitHub" if manual_merge?

        "Review on GitHub"
      end

      def guidance_instruction
        return held_review_instruction if held_for_review?
        return stalled_instruction if stalled_run
        return stale_approval_instruction if stale_approval?
        return "Review the current changes and make the manual merge decision on GitHub. Paid will not merge this pull request automatically." if manual_merge?

        "Approve the current revision on GitHub. Paid will reevaluate it on a later scan, subject to all remaining checks and policy."
      end

      def held_review_instruction
        return "Review the current changes and make the manual merge decision on GitHub. Paid will not merge this pull request automatically." if manual_merge?

        "Review the current changes and remove the hold when automatic merging may resume."
      end

      def stalled_instruction
        "Inspect run ##{stalled_run.id} and its failure, then retry the source issue when automation should resume. " \
          "This request does not mean the pull request is ready to merge."
      end

      def stall_evidence
        return {} unless stalled_run

        {
          run_id: stalled_run.id,
          run_status: stalled_run.status,
          source_issue_number: stalled_run.issue&.github_number
        }.compact
      end

      def run_status
        { "timeout" => "a timed out run", "cancelled" => "a cancelled run" }
          .fetch(stalled_run.status, "a #{stalled_run.status.humanize.downcase} run")
      end

      def stale_approval_instruction
        explanation = "Commits were added after the recorded approval, so Paid treats that approval as stale even if GitHub still shows Approved."
        return "#{explanation} Review the current changes and make the manual merge decision on GitHub. Re-approval alone will not cause Paid to merge it." if manual_merge?

        "#{explanation} Review and approve the current revision on GitHub; Paid will reevaluate it on a later scan, subject to all remaining checks and policy."
      end

      def display_blockers
        blockers.map do |blocker|
          blocker.merge("next_action" => blocker_next_action(blocker))
        end
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
      # @spec AUTO-MERGE-009 INBOX-FOUNDATION-008 INBOX-FOUNDATION-011 OPERATOR-INBOX-002K LABEL-CONTROL-004
      return false unless open_pull_request?
      return true if held_for_review?
      return true if stalled_run
      return false unless reviewable_pr?
      return false if manual_merge? && automatic_merge_active?

      manual_merge? ? manual_action_required? : approval_only_blockers?
    end

    def reviewable_pr?
      issue.pr_review_phase == "ready" &&
        (manual_merge? || automatic_merge_configured?) &&
        !issue.merge_permission_rejected?
    end

    def open_pull_request?
      issue.is_pull_request? && issue.github_state == "open" && !issue.merge_permission_rejected?
    end

    def held_for_review?
      issue.held_for_review?
    end

    # A stopped execution request relies only on persisted, repository-scoped
    # evidence. It deliberately leaves unknown and intentionally deactivated
    # PRs alone; the generated-without-automation shape is the established
    # human opt-out marker used by label recovery.
    # @spec INBOX-FOUNDATION-012
    def stalled_run
      return @stalled_run if defined?(@stalled_run)
      return @stalled_run = nil unless stall_eligible?
      return @stalled_run = nil if correlated_runs.where(status: AgentRun::UNFINISHED_STATUSES).exists?

      @stalled_run = correlated_runs
        .where(status: AgentRun::TERMINAL_FAILURE_STATUSES)
        .where("agent_runs.completed_at <= ?", STALL_GRACE_PERIOD.ago)
        .order(completed_at: :desc, id: :desc)
        .first
    end

    def stall_eligible?
      project = issue.project
      return false unless project.pr_target == "own_repo" && project.auto_add_labels_enabled?
      return false if issue.pr_review_phase == "ready" || issue.github_updated_at < STALL_CANDIDATE_WINDOW.ago

      generated = project.generated_label_name
      automation = project.automation_label_name
      !issue.has_label?(generated) && !issue.has_label?(automation)
    end

    def correlated_runs
      @correlated_runs ||= begin
        clauses = []
        values = {}
        if issue.parent_issue_id
          clauses << "agent_runs.issue_id = :source_issue_id"
          values[:source_issue_id] = issue.parent_issue_id
        end
        clauses << "agent_runs.pull_request_number = :pr_number"
        values[:pr_number] = issue.github_number
        if issue.github_url.present?
          clauses << "agent_runs.pull_request_url = :pr_url"
          values[:pr_url] = issue.github_url
        end
        if issue.last_scanned_head_sha.present?
          clauses << "agent_runs.result_commit_sha = :head_sha"
          values[:head_sha] = issue.last_scanned_head_sha
        end

        issue.project.agent_runs.where(goal: "create_pr").where(clauses.join(" OR "), values)
      end
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
