# frozen_string_literal: true

module Inbox
  # Persists scanner-observed approval state at the same boundary as the issue
  # assessment snapshot. Event keys include the assessed revision so scanner
  # replay is idempotent while a later revision remains distinct.
  # @spec OPERATOR-INBOX-022
  class MergeAssessmentHistoryRecorder
    def self.call(...) = new(...).call

    def initialize(issue:, previous_snapshot:, snapshot:, scanned_at:, head_sha:, approval_evidence: {})
      @issue = issue
      @snapshot = snapshot&.deep_stringify_keys
      @scanned_at = scanned_at
      @head_sha = head_sha
      @approval_evidence = approval_evidence.deep_stringify_keys
    end

    def call
      return if snapshot.blank?

      record_invalidation if stale_approval?
      record_approval if explicit_approval?
      record_manual_merge if approval_complete? && manual_merge?
    end

    private

    attr_reader :approval_evidence, :head_sha, :issue, :scanned_at, :snapshot

    def record_invalidation
      stale_approval_entries.each { |stale| record_invalidation_for(stale) }
    end

    def record_invalidation_for(stale)
      revision = stale["current_revision"] || head_sha
      actor = stale["approver_login"] || "GitHub"
      identity = [ actor, stale["approved_revision"] ].compact.join(":")
      record("invalidation:#{identity}", "Approval invalidated by newer revision", actor,
        "github", "failed", revision)
    end

    def stale_approval_entries
      evidence = stale_blocker.fetch("approval_evidence", {}).deep_stringify_keys
      entries = Array(evidence["stale_approvals"])
      entries.presence || [ evidence ]
    end

    def record_approval
      record("approval", "Owner approval recorded", approval_evidence.fetch("approver_login"),
        "github", "completed", approval_evidence.fetch("approved_revision"))
    end

    def record_manual_merge
      record("manual-merge", "Manual merge pending", "Paid", "paid", "attempted", head_sha)
    end

    def record(kind, action, actor, source, result, revision)
      InboxHistoryEvent.find_or_create_by!(account: issue.project.account, project: issue.project,
        subject_key: "issue:#{issue.project_id}:#{issue.github_number}",
        event_key: "merge-assessment:#{kind}:#{revision || snapshot_digest}") do |event|
        event.assign_attributes(occurred_at: scanned_at, actor_label: actor, source:, result:, revision:,
          evidence_url: issue.github_url, metadata: { action: })
      end
    end

    def stale_approval?
      stale_blocker.present?
    end

    def stale_blocker
      @stale_blocker ||= failed_blockers.find { |blocker| blocker["signal"] == "reviews_fresh" }
    end

    def approval_complete?
      failed_blockers.empty? && Array(snapshot["not_evaluated"]).empty?
    end

    def explicit_approval?
      approval_evidence.present? && approval_evidence["approved_revision"] == head_sha
    end

    def failed_blockers
      Array(snapshot["failed"])
    end

    def manual_merge?
      issue.project.auto_merge_mode == "off" &&
        !Automation::FeatureActivation.human_pull_request_auto_merge_enabled?(
          project: issue.project, pull_request: issue
        )
    end

    def snapshot_digest
      Digest::SHA256.hexdigest(snapshot.to_json)
    end
  end
end
