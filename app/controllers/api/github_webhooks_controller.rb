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

      record_webhook_timestamp(pr["number"], :pull_request_review)

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

      record_webhook_timestamp(pr["number"], :pull_request)

      # Only act on merge events — other PR actions (opened, synchronize, etc.)
      # are not relevant to human feedback quality signals.
      unless action == "closed" && pr["merged"] == true
        head :ok
        return
      end

      notify_merge_subscribers(pr["number"])

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
        record_webhook_timestamp(pr_number, :issue_comment)
        find_agent_run(pr_number)
      else
        record_webhook_timestamp(issue["number"], :issue_comment)
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

      # Record webhook timestamp for all check_suite events (not just action=completed)
      # so the PR scanner can skip check_run fetches when check_suite already delivered state.
      record_webhook_timestamp_for_check_suite

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

      record_webhook_timestamp_for_check_run

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
      # NOTE: completed review-goal lookups use the dedicated
      # idx_agent_runs_review_feedback_lookup composite index because the
      # active-run unique index only covers queued/pending/running/paused rows.
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

    def notify_merge_subscribers(pr_number)
      return unless @project && pr_number

      issue = @project.issues.find_by(github_number: pr_number, is_pull_request: true)
      return unless issue

      IssueMergeSubscriptions::Deliver.call(issue: issue, event: :merged)
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

    # Records the webhook timestamp on the corresponding Issue row so that
    # ScanPaidPrsActivity can skip redundant fetches within the poll interval window.
    #
    # @param pr_number [Integer, nil] The GitHub PR number, or nil for issues.
    # @param event_type [Symbol] One of :pull_request_review, :pull_request, :issue_comment.
    def record_webhook_timestamp(pr_number, event_type)
      return unless @project && pr_number

      issue = @project.issues.find_by(github_number: pr_number, is_pull_request: true)
      return unless issue

      column = case event_type
               when :pull_request_review then "pull_request_review_webhook_at"
               when :pull_request then "pull_request_webhook_at"
               when :issue_comment then "issue_comment_webhook_at"
               else return
               end

      issue.update_column(column, Time.current)
    rescue StandardError => e
      Rails.logger.warn(
        message: "webhook.timestamp_record_failed",
        project_id: @project.id,
        pr_number: pr_number,
        event_type: event_type,
        error: e.message
      )
    end

    # Records check_suite webhook timestamp for all associated PRs.
    def record_webhook_timestamp_for_check_suite
      return unless @project

      pull_requests = payload.dig("check_suite", "pull_requests") || []
      pull_requests.each do |pr_ref|
        pr_number = pr_ref["number"]
        next unless pr_number

        issue = @project.issues.find_by(github_number: pr_number, is_pull_request: true)
        next unless issue

        issue.update_column("check_suite_webhook_at", Time.current)
      rescue StandardError => e
        Rails.logger.warn(
          message: "webhook.check_suite_timestamp_record_failed",
          project_id: @project.id,
          pr_number: pr_number,
          error: e.message
        )
      end
    end

    # Records check_run webhook timestamp for all associated PRs.
    def record_webhook_timestamp_for_check_run
      return unless @project

      pull_requests = payload.dig("check_run", "pull_requests") || []
      pull_requests.each do |pr_ref|
        pr_number = pr_ref["number"]
        next unless pr_number

        issue = @project.issues.find_by(github_number: pr_number, is_pull_request: true)
        next unless issue

        issue.update_column("check_run_webhook_at", Time.current)
      rescue StandardError => e
        Rails.logger.warn(
          message: "webhook.check_run_timestamp_record_failed",
          project_id: @project.id,
          pr_number: pr_number,
          error: e.message
        )
      end
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
