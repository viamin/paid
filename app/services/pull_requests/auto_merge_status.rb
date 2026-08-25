# frozen_string_literal: true

module PullRequests
  # Builds a sanitized auto-merge diagnostic snapshot for PR detail payloads.
  # Reports a merged PR as `merged` even when a prior merge-permission
  # rejection is still persisted (e.g. when the PR was merged out-of-band
  # after the rejection and the rejection flag was never cleared). Otherwise
  # prefers persisted merge-permission rejection history when present, and
  # derives the current blocker state from live PR/check data.
  # @spec CHAT-API-011
  class AutoMergeStatus
    include CiStatusVerification

    def self.call(issue:, project:)
      new(issue:, project:).call
    end

    def initialize(issue:, project:)
      @issue = issue
      @project = project
    end

    def call
      # Check the live/derived merge state before the persisted rejection flag:
      # `FetchIssuesActivity#close_stale_pull_requests` flips
      # `pr_review_phase: "merged"` and `github_state: "closed"` when a PR is
      # merged out-of-band, but does not clear `merge_permission_rejected_at`.
      # A merged PR must report as `merged` regardless of any stale rejection
      # history from before it landed.
      return merged_status if merged?
      return merge_permission_rejected_status if issue.merge_permission_rejected?
      return auto_merge_disabled_status unless project.auto_merge_enabled?
      return credentials_unavailable_status unless client
      return not_mergeable_status unless mergeable?(pull_request)
      return checks_not_green_status unless all_checks_green?(client, project, pull_request)

      ready_status
    rescue GithubClient::Error => e
      diagnostics_unavailable_status(e.message)
    end

    private

    attr_reader :issue, :project

    def ci_log_component
      "pull_request_details"
    end

    def pull_request
      @pull_request ||= client.pull_request(project.full_name, issue.github_number)
    end

    def client
      return @client if defined?(@client)

      # `Project#client` already gates the app-backed path via
      # `github_credential` (which calls `credential_active?`), but the PAT
      # path goes straight to `github_token&.client` without checking the
      # token's `active?` flag. A revoked/expired token would otherwise reach
      # `pull_request`, raise `GithubClient::Error`, and surface as
      # `diagnostics_unavailable` after an API failure instead of the
      # intended `credentials_unavailable` state this feature is supposed to
      # explain. Mirror the app-backed guard here before memoizing so the
      # inactive-credential case is detected up front.
      @client = if !app_backed? && project.github_token.present? && !project.github_token.active?
        nil
      else
        project.client
      end
    rescue Github::AppInstallation::Error
      @client = nil
    end

    def merged?
      return issue.merged_phase? if client.nil?

      merged_at(pull_request).present?
    end

    def merged_at(pr_data)
      pr_data.respond_to?(:merged_at) ? pr_data.merged_at : pr_data[:merged_at]
    end

    def mergeable?(pr_data)
      pr_data.respond_to?(:mergeable) ? pr_data.mergeable == true : pr_data[:mergeable] == true
    end

    def merge_permission_rejected_status
      status_payload(
        auto_merge_status: "blocked",
        last_auto_merge_attempt_at: issue.merge_permission_rejected_at,
        reason_code: "merge_permission_rejected",
        sanitized_message: AgentRun::ErrorMessageSanitizer.call(text: issue.merge_permission_rejection_reason),
        merge_permission_rejected: true,
        cooldown_until: issue.merge_permission_rejected_at + Issue::MERGE_PERMISSION_RETRY_COOLDOWN,
        next_action: merge_permission_next_action
      )
    end

    def merged_status
      status_payload(
        auto_merge_status: "merged",
        next_action: "No action required."
      )
    end

    def auto_merge_disabled_status
      status_payload(
        auto_merge_status: "not_attempted",
        reason_code: "auto_merge_disabled",
        sanitized_message: "Auto-merge is not enabled for this project.",
        next_action: "Enable auto-merge for the project or merge this pull request manually."
      )
    end

    def credentials_unavailable_status
      status_payload(
        auto_merge_status: "not_attempted",
        reason_code: "credentials_unavailable",
        sanitized_message: "Live auto-merge diagnostics are unavailable because the project has no active GitHub credential.",
        next_action: "Configure an active GitHub App installation or personal access token for this project."
      )
    end

    def not_mergeable_status
      status_payload(
        auto_merge_status: "blocked",
        reason_code: "not_mergeable",
        sanitized_message: "GitHub is not reporting this pull request as mergeable yet.",
        next_action: "Resolve merge conflicts or other mergeability blockers, then wait for the next automatic check."
      )
    end

    def checks_not_green_status
      status_payload(
        auto_merge_status: "blocked",
        reason_code: "checks_not_green",
        sanitized_message: "Required checks are not green yet.",
        next_action: "Wait for required checks to pass, then let auto-merge evaluate the pull request again."
      )
    end

    def ready_status
      status_payload(
        auto_merge_status: "ready",
        next_action: "Wait for the next automatic merge evaluation or merge this pull request manually."
      )
    end

    def diagnostics_unavailable_status(message)
      status_payload(
        auto_merge_status: "unavailable",
        reason_code: "diagnostics_unavailable",
        sanitized_message: AgentRun::ErrorMessageSanitizer.call(text: message),
        next_action: "Retry once GitHub diagnostics are available, or inspect the project's GitHub credential configuration."
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

    def app_backed?
      project.github_installation_id.present? || project.github_installation.present?
    end

    def status_payload(auto_merge_status:, last_auto_merge_attempt_at: nil, reason_code: nil,
      sanitized_message: nil, merge_permission_rejected: false, cooldown_until: nil, next_action: nil)
      {
        last_auto_merge_attempt_at:,
        auto_merge_status:,
        reason_code:,
        sanitized_message:,
        credential_mode:,
        merge_permission_rejected:,
        cooldown_until:,
        next_action:
      }
    end
  end
end
