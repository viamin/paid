# frozen_string_literal: true

module PullRequests
  # Clears an escalation on behalf of the owner, without waiting for a scan
  # cycle. Deciding what the pull request needs next is the scanner's job, so
  # this queues no run — clearing the hold returns the PR to the scan, which
  # picks the work on its next pass.
  #
  # For a `pr_auto_continue_token_limit` escalation, +Issue#clear_escalation!+
  # stamps `pr_auto_continue_token_limit_overridden_at`, granting a standing
  # per-PR override of the project's automatic-run token cap. Because this
  # path is reachable from any project member with `run_agent?` (unlike the
  # label-removal and draft-conversion paths, which require repo-write access
  # by an allowlisted GitHub user), the waiver is recorded as an
  # OrchestrationDecision and a structured log event so the actor, the PR,
  # and the escalation reason survive as an audit trail.
  #
  # @spec PR-ESCALATION-014 @spec PR-ESCALATION-015 @spec PR-ESCALATION-016
  class Unblock
    ESCALATED_LABEL = Issue::ESCALATED_LABEL

    Result = Data.define(:success, :error, :pull_request) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(pull_request:, actor: nil, draft: false)
      @pull_request = pull_request
      @actor = actor
      @draft = draft
    end

    def call
      error = nil
      prior_escalation_reason = nil
      token_limit_waiver_granted = false

      # Guards run inside the lock against reloaded state: a concurrent
      # MarkEscalatedActivity or a PR closing between render and click would
      # otherwise pass a stale check and clear anyway.
      pull_request.with_lock do
        if pull_request.github_state != "open"
          error = :not_open
        elsif !pull_request.escalated_phase?
          error = :not_escalated
        else
          prior_escalation_reason = pull_request.pr_escalation_reason
          token_limit_waiver_granted = prior_escalation_reason == Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT
          pull_request.clear_escalation!(draft: draft)
        end
      end

      return failure(error) if error

      record_audit_trail(prior_escalation_reason: prior_escalation_reason,
        token_limit_waiver_granted: token_limit_waiver_granted)
      remove_escalated_label
      Result.new(success: true, error: nil, pull_request: pull_request)
    end

    private

    attr_reader :pull_request, :actor, :draft

    def record_audit_trail(prior_escalation_reason:, token_limit_waiver_granted:)
      OrchestrationDecision.record(
        project: pull_request.project,
        issue: pull_request,
        decision_point: "manual_unblock",
        action: "dismiss_escalation",
        status: "applied",
        signals: {
          prior_escalation_reason: prior_escalation_reason,
          token_limit_waiver_granted: token_limit_waiver_granted,
          actor_user_id: actor&.id,
          actor_email: actor&.email,
          draft: draft
        },
        result: {
          phase: pull_request.pr_review_phase,
          escalation_cleared: true
        }
      )

      Rails.logger.info(
        message: "pr_escalation.manual_unblock",
        component: "pr_review",
        issue_id: pull_request.id,
        pr_number: pull_request.github_number,
        project_id: pull_request.project_id,
        prior_escalation_reason: prior_escalation_reason,
        token_limit_waiver_granted: token_limit_waiver_granted,
        actor_user_id: actor&.id
      )
    end

    # Best-effort: the local clearing is what unblocks automation, and a GitHub
    # failure must not leave it half-applied. A stale label on a PR that is no
    # longer escalated does not re-escalate anything, and the next sync
    # reconciles it.
    def remove_escalated_label
      project = pull_request.project
      client = project.client
      return unless client

      client.remove_label_from_issue(project.full_name, pull_request.github_number, ESCALATED_LABEL)
    rescue GithubClient::Error, Faraday::Error => e
      Rails.logger.warn(
        message: "pr_escalation.label_removal_failed",
        issue_id: pull_request.id,
        pr_number: pull_request.github_number,
        error_class: e.class.name,
        error: e.message
      )
    end

    def failure(error)
      Result.new(success: false, error: error, pull_request: pull_request)
    end
  end
end
