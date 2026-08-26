# frozen_string_literal: true

module Projects
  class GithubDiagnostics
    RECENT_FAILURE_LIMIT = 5
    RECENT_FAILURE_CANDIDATE_LIMIT = RECENT_FAILURE_LIMIT * 10
    WORKFLOWS_PERMISSION_CODE = "missing_workflows_permission"
    GENERIC_PERMISSION_CODE = "github_permission_rejected"

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      {
        credential_mode: project.github_auth_source,
        primary_credential: primary_credential_payload,
        github_app: github_app_payload,
        webhook: {
          configured: project.webhook_secret.present?
        },
        pat_fallback: pat_fallback_payload,
        recent_permission_failures: recent_permission_failures,
        recommended_action: recommended_action
      }
    end

    private

    attr_reader :project

    def primary_credential_payload
      if app_backed?
        {
          source: "app",
          configured: installation.present?,
          status: installation_lifecycle_status,
          health: app_health_status,
          available: installation_lifecycle_status == "active" && app_health_status == "available"
        }
      else
        {
          source: "pat",
          configured: primary_token.present?,
          status: token_lifecycle_status(primary_token),
          health: token_health_status(primary_token),
          available: token_lifecycle_status(primary_token) == "active" && token_health_status(primary_token) == "available",
          token: safe_token_ref(primary_token)
        }
      end
    end

    def github_app_payload
      return { installation_present: false, status: "not_configured", health: "not_configured", repository_access: false } unless app_backed?

      {
        installation_present: installation.present?,
        installation_id: installation&.github_installation_id,
        display_name: installation&.display_name,
        status: installation_lifecycle_status,
        health: app_health_status,
        repository_access: installation&.covers_repository?(project.full_name) || false
      }
    end

    def pat_fallback_payload
      {
        enabled: project.git_push_pat_fallback_enabled?,
        configured: project.git_push_pat_fallback_configured?,
        status: fallback_lifecycle_status,
        health: fallback_health_status,
        token: safe_token_ref(fallback_token)
      }
    end

    def recent_permission_failures # @spec GITHUB-SYNC-009
      (merge_permission_failures + push_permission_failures)
        .sort_by { |failure| failure[:occurred_at] || Time.at(0) }
        .reverse
        .first(RECENT_FAILURE_LIMIT)
    end

    def recommended_action
      return action("configure_project_webhook_secret",
        "Configure this project's GitHub webhook secret so Paid can verify inbound GitHub webhooks.") unless project.webhook_secret.present?

      if app_backed?
        return action("connect_github_app_installation",
          "Connect a GitHub App installation for this repository.") unless installation.present?
        return action("restore_github_app_installation",
          "Restore or reinstall the GitHub App for this repository.") unless installation_lifecycle_status == "active"
        return action("grant_github_app_repository_access",
          "Grant the GitHub App installation access to #{project.full_name}.") unless installation.covers_repository?(project.full_name)
      end

      latest_failure = recent_permission_failures.first
      return recommended_action_for_failure(latest_failure) if latest_failure

      if !app_backed? && token_lifecycle_status(primary_token) != "active"
        return action("rotate_primary_pat",
          "Replace or reactivate the project's primary GitHub PAT so repository operations can succeed.")
      end

      nil
    end

    def recommended_action_for_failure(failure)
      return unless failure
      return unless failure[:code] == WORKFLOWS_PERMISSION_CODE

      if project.git_push_pat_fallback_enabled? && %w[revoked expired].include?(fallback_lifecycle_status)
        return action(
          "grant_workflows_permission_or_rotate_pat_fallback",
          "Grant the GitHub App the `workflows` permission, or rotate/reactivate the project's PAT push fallback before retrying."
        )
      end

      unless project.git_push_pat_fallback_configured?
        return action(
          "grant_workflows_permission_or_enable_pat_fallback",
          "Grant the GitHub App the `workflows` permission, or enable a PAT push fallback for this project before retrying."
        )
      end

      action(
        "grant_workflows_permission_or_retry",
        "Grant the GitHub App the `workflows` permission, or retry once the fallback PAT is confirmed healthy."
      )
    end

    def build_failure(issue:, kind:, occurred_at:, reason:)
      code, message = classify_reason(reason)

      {
        kind: kind,
        code: code,
        message: message,
        issue_id: issue.id,
        issue_number: issue.github_number,
        pull_request: issue.is_pull_request?,
        occurred_at: occurred_at
      }
    end

    def build_failure_from_attempt(attempt)
      code, fallback_message = classify_reason(attempt.reason_code)

      {
        kind: "merge",
        code: code,
        message: attempt.sanitized_message.presence || fallback_message,
        issue_id: attempt.issue_id,
        issue_number: attempt.issue.github_number,
        pull_request: attempt.issue.is_pull_request?,
        occurred_at: attempt.attempted_at
      }
    end

    def classify_reason(reason)
      normalized = reason.to_s.downcase
      if normalized == AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION
        return [
          WORKFLOWS_PERMISSION_CODE,
          "GitHub rejected the operation because the App lacks the `workflows` permission required for workflow file changes."
        ]
      end

      if normalized.include?("workflows") && normalized.include?("permission")
        return [
          WORKFLOWS_PERMISSION_CODE,
          "GitHub rejected the operation because the App lacks the `workflows` permission required for workflow file changes."
        ]
      end

      [
        GENERIC_PERMISSION_CODE,
        "GitHub rejected the operation because the current credential lacks a required permission."
      ]
    end

    def merge_permission_failures
      attempts = merge_permission_attempts
      attempts.map { |attempt| build_failure_from_attempt(attempt) } +
        legacy_merge_permission_failures(excluding_issue_ids: attempts.map(&:issue_id))
    end

    def merge_permission_attempts
      project.auto_merge_attempts
        .includes(:issue)
        .permission_blockers
        .recent
        .limit(RECENT_FAILURE_CANDIDATE_LIMIT)
        .to_a
        .uniq { |attempt| attempt.issue_id }
    end

    # Blockers recorded before the auto_merge_attempts table existed live only
    # on the issue columns, and no backfill copies them into the new table yet,
    # so already-blocked PRs would lose diagnostics on upgrade without this
    # fallback. New rejections write both stores, so issues already covered by
    # attempt rows are excluded to avoid double-reporting the same blocker.
    # TODO(#3454): drop this fallback once historical blockers are backfilled
    # into auto_merge_attempts.
    def legacy_merge_permission_failures(excluding_issue_ids:)
      legacy_merge_permission_issues(excluding_issue_ids).map do |issue|
        build_failure(
          issue: issue,
          kind: "merge",
          occurred_at: issue.merge_permission_rejected_at,
          reason: issue.merge_permission_rejection_reason
        )
      end
    end

    def legacy_merge_permission_issues(excluding_issue_ids)
      scope = project.issues.where.not(merge_permission_rejected_at: nil)
      scope = scope.where.not(id: excluding_issue_ids) if excluding_issue_ids.present?
      scope.order(merge_permission_rejected_at: :desc).limit(RECENT_FAILURE_CANDIDATE_LIMIT)
    end

    def push_permission_failures
      scoped_push_failure_issues.map do |issue|
        build_failure(
          issue: issue,
          kind: "push",
          occurred_at: issue.runner_retry_abandoned_at,
          reason: issue.runner_retry_abandon_reason.to_s.delete_prefix("#{Issue::PUSH_PERMISSION_ABANDON_PREFIX} ").presence
        )
      end
    end

    def scoped_push_failure_issues
      project.issues
        .where.not(runner_retry_abandoned_at: nil)
        .where("runner_retry_abandon_reason LIKE ?", "#{Issue::PUSH_PERMISSION_ABANDON_PREFIX}%")
        .order(runner_retry_abandoned_at: :desc)
        .limit(RECENT_FAILURE_CANDIDATE_LIMIT)
    end

    def app_backed?
      project.github_auth_source == "app"
    end

    def installation
      project.github_installation
    end

    def primary_token
      project.github_token
    end

    def fallback_token
      project.git_push_fallback_token
    end

    def installation_lifecycle_status
      return "missing" unless installation.present?
      return "suspended" if installation.suspended?
      return "revoked" if installation.revoked?

      "active"
    end

    def token_lifecycle_status(token)
      return "missing" unless token.present?
      return "revoked" if token.revoked?
      return "expired" if token.expired?

      "active"
    end

    def fallback_lifecycle_status
      return "not_applicable" unless app_backed?
      return "disabled" unless project.git_push_pat_fallback_enabled?
      return "missing" unless fallback_token.present?

      token_lifecycle_status(fallback_token)
    end

    def app_health_status
      return "not_configured" unless installation.present?
      return "unavailable" unless installation_lifecycle_status == "active"

      endpoint_health(project.github_health_endpoint)
    end

    def token_health_status(token)
      return "not_configured" unless token.present?
      return "unavailable" unless token_lifecycle_status(token) == "active"

      endpoint_health(GithubHealthState.endpoint_for_github_token(token.id))
    end

    def fallback_health_status
      return "not_applicable" unless app_backed?
      return "not_configured" unless fallback_token.present?
      return "unavailable" unless fallback_lifecycle_status == "active"

      endpoint_health(GithubHealthState.endpoint_for_github_token(fallback_token.id))
    end

    def endpoint_health(endpoint)
      state = GithubHealthState.find_by(endpoint: endpoint)
      return "available" unless state

      return "rate_limited" if state.rate_limited?
      return "circuit_open" if state.circuit_open?
      return "recovering" if state.circuit_half_open?

      "available"
    end

    def safe_token_ref(token)
      return unless token

      {
        id: token.id,
        name: token.name
      }
    end

    def action(code, message)
      {
        code: code,
        message: message
      }
    end
  end
end
