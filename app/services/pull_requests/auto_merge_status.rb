# frozen_string_literal: true

module PullRequests
  # Builds a sanitized auto-merge diagnostic snapshot for PR detail payloads.
  # Reports a merged PR as `merged` even when a prior merge-permission
  # rejection is still persisted (e.g. when the PR was merged out-of-band
  # after the rejection and the rejection flag was never cleared). Otherwise
  # formats the latest persisted scan snapshot instead of re-evaluating
  # eligibility from live GitHub data.
  # @spec CHAT-API-011
  # @spec AUTO-MERGE-005
  class AutoMergeStatus
    def self.call(issue:, project:, live_pull_request: nil)
      new(issue:, project:, live_pull_request:).call
    end

    def initialize(issue:, project:, live_pull_request:)
      @issue = issue
      @project = project
      @live_pull_request = live_pull_request
    end

    def call
      return merged_status if merged?
      return merged_status if live_merged?
      return merge_permission_rejected_status if issue.merge_permission_rejected?
      return auto_merge_disabled_status unless project.auto_merge_enabled?
      return credentials_unavailable_status unless credentials_available?
      return diagnostics_unavailable_status if blockers_snapshot.nil?

      failed = blockers_snapshot.fetch("failed", [])
      return blocked_status(failed) if failed.any?

      ready_status
    end

    private

    attr_reader :issue, :project, :live_pull_request

    def merged?
      issue.merged_phase?
    end

    def live_merged?
      live_pull_request&.merged == true || live_pull_request&.merged_at.present?
    end

    def merge_permission_rejected_status
      attempt = latest_attempt
      status_payload(
        auto_merge_status: "blocked",
        last_auto_merge_attempt_at: attempt&.attempted_at || issue.merge_permission_rejected_at,
        reason_code: attempt&.reason_code || AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
        sanitized_message: attempt&.sanitized_message || AgentRun::ErrorMessageSanitizer.call(text: issue.merge_permission_rejection_reason),
        credential_mode: attempt&.credential_mode,
        merge_permission_rejected: true,
        cooldown_until: issue.merge_permission_rejected_at + Issue::MERGE_PERMISSION_RETRY_COOLDOWN,
        next_action: merge_permission_next_action
      )
    end

    def blocked_status(failed)
      primary = failed.first
      status_payload(
        auto_merge_status: "blocked",
        last_auto_merge_attempt_at: latest_attempt&.attempted_at,
        reason_code: primary["reason_code"],
        sanitized_message: primary["sanitized_message"],
        next_action: primary["next_action"],
        blockers: failed
      )
    end

    def merged_status
      status_payload(
        auto_merge_status: "merged",
        last_auto_merge_attempt_at: latest_attempt&.attempted_at,
        next_action: "No action required.",
        blockers: []
      )
    end

    def auto_merge_disabled_status
      status_payload(
        auto_merge_status: "not_attempted",
        last_auto_merge_attempt_at: latest_attempt&.attempted_at,
        reason_code: "auto_merge_disabled",
        sanitized_message: "Auto-merge is not enabled for this project.",
        next_action: "Enable auto-merge for the project or merge this pull request manually.",
        blockers: []
      )
    end

    def credentials_unavailable_status
      status_payload(
        auto_merge_status: "not_attempted",
        last_auto_merge_attempt_at: latest_attempt&.attempted_at,
        reason_code: "credentials_unavailable",
        sanitized_message: "Auto-merge diagnostics are unavailable because the project has no active GitHub credential.",
        next_action: "Configure an active GitHub App installation or personal access token for this project.",
        blockers: []
      )
    end

    def ready_status
      status_payload(
        auto_merge_status: "ready",
        last_auto_merge_attempt_at: latest_attempt&.attempted_at,
        next_action: "Wait for the next automatic merge evaluation or merge this pull request manually.",
        blockers: []
      )
    end

    def diagnostics_unavailable_status
      status_payload(
        auto_merge_status: "unavailable",
        last_auto_merge_attempt_at: latest_attempt&.attempted_at,
        reason_code: "diagnostics_unavailable",
        sanitized_message: "Auto-merge diagnostics are unavailable until Paid completes a PR scan for this pull request.",
        next_action: "Wait for the next PR scan to complete, then check auto-merge diagnostics again.",
        blockers: []
      )
    end

    def merge_permission_next_action
      if project.git_push_pat_fallback_configured?
        "Check the configured PAT fallback credential and the GitHub App permissions, then merge manually or wait for the next automatic check."
      else
        "Grant the GitHub App the required permission (for example `workflows`), configure a PAT fallback if needed, then merge manually or wait for the next automatic check."
      end
    end

    def credential_mode
      return "github_app_with_pat_fallback" if app_backed? && project.git_push_pat_fallback_configured?
      return "github_app" if app_backed?
      return "personal_access_token" if project.github_token.present?

      nil
    end

    def credentials_available?
      return project.github_installation&.active? == true if app_backed?

      project.github_token&.active? == true
    end

    def blockers_snapshot
      return @blockers_snapshot if defined?(@blockers_snapshot)

      snapshot = issue.auto_merge_blockers
      @blockers_snapshot =
        if issue.auto_merge_evaluated_at.present? && snapshot.is_a?(Hash)
          snapshot.deep_stringify_keys
        end
    end

    def app_backed?
      project.github_installation_id.present? || project.github_installation.present?
    end

    def status_payload(auto_merge_status:, last_auto_merge_attempt_at: nil, reason_code: nil,
      sanitized_message: nil, credential_mode: nil, merge_permission_rejected: false, cooldown_until: nil, next_action: nil, blockers: [])
      {
        last_auto_merge_attempt_at:,
        auto_merge_status:,
        reason_code:,
        sanitized_message:,
        credential_mode: credential_mode || self.credential_mode,
        merge_permission_rejected:,
        cooldown_until:,
        next_action:,
        blockers:
      }
    end

    def latest_attempt
      @latest_attempt ||= issue.auto_merge_attempts.recent.first
    end
  end
end
