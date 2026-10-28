# frozen_string_literal: true

module Inbox
  class MergeApproval
    APPROVAL_SIGNALS = %w[owner_approved reviews_fresh].freeze

    def self.call(issue, phase_authorized: nil)
      new(issue, phase_authorized:).call
    end

    # Narrows to rows that could plausibly need an operator before falling back
    # to Ruby for the full `call` signal check (`APPROVAL_SIGNALS`), so
    # counting/listing stays a bounded scan instead of one Issue
    # instantiation per open PR on the account. A structured human hold is
    # intentionally phase-independent: post-processing may have failed after
    # GitHub opened the PR, leaving the local phase stale. Shared by
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
          github_state: "open"
        )
        .where(candidate_conditions)
    end

    def self.candidate_conditions
      Issue.sanitize_sql_array([
        "(projects.label_integration_mode <> 'ignored' AND issues.labels @> :hold_label::jsonb) OR " \
          "(projects.label_integration_mode = 'ignored' AND issues.hold_for_review = TRUE) OR (" \
          "issues.auto_merge_evaluated_at IS NOT NULL AND " \
          "issues.auto_merge_blockers IS NOT NULL AND (" \
          "projects.auto_merge_mode = 'off' OR projects.owner_reviewer_login IS NOT NULL))",
        hold_label: [ Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL ].to_json
      ])
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
        return "Approval is stale for the current revision" if stale_approval?
        return "Manual merge decision on GitHub" if manual_merge?

        "Review on GitHub"
      end

      def guidance_instruction
        return held_review_instruction if held_for_review?
        return stale_approval_instruction if stale_approval?
        return "Review the current changes and make the manual merge decision on GitHub. Paid will not merge this pull request automatically." if manual_merge?

        "Approve the current revision on GitHub. Paid will reevaluate it on a later scan, subject to all remaining checks and policy."
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
      return false unless reviewable_pr?
      return false if manual_merge? && automatic_merge_active?

      manual_merge? ? manual_action_required? : approval_only_blockers?
    end

    def reviewable_pr?
      open_pull_request? &&
        issue.pr_review_phase == "ready" &&
        (manual_merge? || automatic_merge_configured?) &&
        !issue.merge_permission_rejected?
    end

    def open_pull_request?
      issue.is_pull_request? && issue.github_state == "open"
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
