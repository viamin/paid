# frozen_string_literal: true

module Api
  # Receives GitHub webhook events and dispatches to feedback collection services.
  # Verifies the webhook signature using the project's webhook_secret.
  #
  # Supported events:
  #   - pull_request_review: Maps approved/changes_requested/commented to quality scores
  #   - pull_request: Records pr_merged signal when an agent's PR is merged
  #   - issue_comment: Tracks comment activity on agent-created PRs and issues
  class GithubWebhooksController < ActionController::API
    before_action :verify_signature

    # POST /api/github_webhooks
    def create
      event = request.headers["X-GitHub-Event"]

      # Must come before event handlers; also initializes @payload via #payload.
      invalidate_cache(event)

      case event
      when "pull_request_review"
        handle_pull_request_review
      when "pull_request"
        handle_pull_request
      when "issue_comment"
        handle_issue_comment
      when "check_suite"
        handle_check_suite
      when "check_run"
        handle_check_run
      else
        head :ok
      end
    end

    private

    def handle_pull_request_review
      review = payload["review"] || {}
      pr = payload["pull_request"] || {}

      agent_run = find_agent_run(pr["number"])
      unless agent_run
        head :ok
        return
      end

      QualityMetrics::CollectReviewFeedback.call(
        agent_run: agent_run,
        review_state: review["state"],
        reviewer: review.dig("user", "login"),
        review_body: review["body"].to_s
      )
      check_quality_pause(agent_run)

      head :ok
    end

    def handle_pull_request
      action = payload["action"]
      pr = payload["pull_request"] || {}

      # Trigger auto-release evaluation when a release-please PR is opened,
      # updated, or labeled — these events may make it eligible for auto-merge.
      if %w[opened synchronize labeled].include?(action) && @project&.auto_release_enabled?
        enqueue_auto_release_evaluation(pr["number"])
      end

      # Trigger Dependabot auto-merge evaluation when a Dependabot PR is
      # opened or updated.
      if %w[opened synchronize].include?(action) && @project&.auto_merge_dependabot?
        enqueue_dependabot_auto_merge(pr)
      end

      # Only act on merge events — other PR actions (opened, synchronize, etc.)
      # are not relevant to human feedback quality signals.
      unless action == "closed" && pr["merged"] == true
        head :ok
        return
      end

      agent_run = find_agent_run(pr["number"])
      unless agent_run
        head :ok
        return
      end

      QualityMetrics::CollectHumanFeedback.call(
        agent_run: agent_run,
        pr_merged: true,
        feedback_source: "pr_merge"
      )
      check_quality_pause(agent_run)

      head :ok
    end

    def handle_issue_comment
      action = payload["action"]

      # Only track new comments — edits and deletions are not meaningful signals.
      unless action == "created"
        head :ok
        return
      end

      issue = payload["issue"] || {}
      comment = payload["comment"] || {}

      # GitHub sends issue_comment events for both issues and PRs.
      # PR comments include a pull_request key in the issue payload.
      pr_number = issue.dig("pull_request") ? issue["number"] : nil

      agent_run = if pr_number
        find_agent_run(pr_number)
      else
        find_agent_run_by_issue(issue["number"])
      end

      unless agent_run
        head :ok
        return
      end

      QualityMetrics::CollectCommentFeedback.call(
        agent_run: agent_run,
        commenter: comment.dig("user", "login"),
        comment_id: comment["id"]
      )
      check_quality_pause(agent_run)

      head :ok
    end

    def handle_check_suite
      return head(:ok) unless payload["action"] == "completed"

      if @project&.auto_release_enabled?
        enqueue_auto_release_evaluation
      end

      if @project&.auto_merge_dependabot?
        enqueue_dependabot_auto_merge_from_check(payload.dig("check_suite", "pull_requests"))
      end

      head :ok
    end

    def handle_check_run
      return head(:ok) unless payload["action"] == "completed"

      if @project&.auto_release_enabled?
        enqueue_auto_release_evaluation
      end

      if @project&.auto_merge_dependabot?
        pr_refs = payload.dig("check_run", "pull_requests")
        enqueue_dependabot_auto_merge_from_check(pr_refs)
      end

      head :ok
    end

    def enqueue_auto_release_evaluation(pr_number = nil)
      if pr_number
        AutoReleaseEvaluationJob.perform_later(@project.id, pr_number: pr_number)
      else
        AutoReleaseEvaluationJob.perform_later(@project.id)
      end
    rescue => e
      Rails.logger.warn(
        message: "auto_release.enqueue_failed",
        project_id: @project.id,
        error: e.message
      )
    end

    DEPENDABOT_LOGIN_PREFIX = "dependabot"

    def enqueue_dependabot_auto_merge(pr)
      author = pr.dig("user", "login").to_s.downcase
      return unless author.start_with?(DEPENDABOT_LOGIN_PREFIX)

      DependabotAutoMergeJob.perform_later(@project.id, pr_number: pr["number"])
    rescue => e
      Rails.logger.warn(
        message: "dependabot_auto_merge.enqueue_failed",
        project_id: @project.id,
        error: e.message
      )
    end

    def enqueue_dependabot_auto_merge_from_check(pull_requests)
      return unless pull_requests.is_a?(Array)

      # check_suite/check_run payloads include only lightweight PR refs without
      # a "user" object, so we cannot filter by author here. The job itself
      # fetches the full PR and checks the author before proceeding.
      pull_requests.each do |pr_ref|
        DependabotAutoMergeJob.perform_later(@project.id, pr_number: pr_ref["number"])
      end
    rescue => e
      Rails.logger.warn(
        message: "dependabot_auto_merge.enqueue_failed",
        project_id: @project.id,
        error: e.message
      )
    end

    # Shared lookup used by all three event handlers (pull_request_review,
    # pull_request, issue_comment). The review-goal fallback intentionally
    # applies to every event type: a merged PR or issue comment on a PR that
    # was reviewed by an agent should still attribute the signal.
    def find_agent_run(pr_number)
      return nil unless @project && pr_number

      # Only record feedback for successful (completed) runs to avoid skewing
      # metrics — mirrors the guard in HumanFeedbackCollectionJob#perform.
      #
      # Review-goal runs set source_pull_request_number (the PR they reviewed)
      # instead of pull_request_number, so fall back to that lookup.
      # The HumanFeedbackCollectionJob side already handles this via
      # CollectReviewReactionFeedback, which queries source_pull_request_number
      # directly for review-goal runs.
      #
      # NOTE: the existing partial unique index on (project_id,
      # source_pull_request_number) covers active runs only and does not help
      # this completed-status query. At current volume that is fine.
      # TODO(#943): if review-goal feedback volume grows, consider a composite
      # index on (project_id, source_pull_request_number, status).
      @project.agent_runs
        .where(pull_request_number: pr_number, status: "completed")
        .order(created_at: :desc)
        .first ||
        @project.agent_runs
          .where(source_pull_request_number: pr_number, goal: "review", status: "completed")
          .order(created_at: :desc)
          .first
    end

    def find_agent_run_by_issue(issue_number)
      return nil unless @project && issue_number

      @project.agent_runs
        .where(created_issue_number: issue_number, status: "completed")
        .order(created_at: :desc)
        .first
    end

    def invalidate_cache(event)
      Github::CacheInvalidator.call(
        project: @project,
        event: event,
        payload: payload
      )
    rescue StandardError => e
      Rails.logger.warn(
        message: "github_cache.invalidation_failed",
        event: event,
        error: e.message
      )
    end

    def check_quality_pause(agent_run)
      QualityPause::Check.call(agent_run: agent_run)
    end

    def payload
      @payload ||= JSON.parse(request.body.read)
    rescue JSON::ParserError
      {}
    end

    def verify_signature
      signature = request.headers["X-Hub-Signature-256"]
      unless signature
        head :unauthorized
        return
      end

      request.body.rewind
      body = request.body.read
      request.body.rewind

      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      repo_data = parsed&.dig("repository")
      unless repo_data
        head :bad_request
        return
      end

      # github_id is unique per account_id, not globally — the same repo can be
      # connected under multiple accounts. We try all matching projects and
      # verify the signature against each one's webhook_secret; the one that
      # matches is the correct project.
      github_id = repo_data["id"]
      candidates = if github_id
        Project.where(github_id: github_id)
      else
        owner, repo = repo_data["full_name"].to_s.split("/", 2)
        Project.where(owner: owner, repo: repo)
      end

      @project = candidates.find do |project|
        next unless project.webhook_secret.present?

        expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", project.webhook_secret, body)}"
        signature.bytesize == expected.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(expected, signature)
      end

      head :unauthorized unless @project
    end
  end
end
