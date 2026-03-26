# frozen_string_literal: true

module Api
  # Receives GitHub webhook events for PR reviews and reactions.
  # Verifies the webhook signature using the project's webhook_secret,
  # then dispatches to the appropriate feedback collection service.
  #
  # Supported events:
  #   - pull_request_review: Maps approved/changes_requested/commented to quality scores
  #   - pull_request_review_comment: Tracks review comment activity
  class GithubWebhooksController < ActionController::API
    before_action :verify_signature

    # POST /api/github_webhooks
    def create
      event = request.headers["X-GitHub-Event"]

      case event
      when "pull_request_review"
        handle_pull_request_review
      else
        head :ok
      end
    end

    private

    def handle_pull_request_review
      review = payload.dig("review") || {}
      pr = payload.dig("pull_request") || {}
      repo_full_name = payload.dig("repository", "full_name")

      agent_run = find_agent_run(repo_full_name, pr["number"])
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

      head :ok
    end

    def find_agent_run(repo_full_name, pr_number)
      return nil unless repo_full_name && pr_number

      project = Project.find_by(owner: repo_full_name.split("/").first, repo: repo_full_name.split("/").last)
      return nil unless project

      project.agent_runs
        .where(pull_request_number: pr_number)
        .order(created_at: :desc)
        .first
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

      repo_full_name = begin
        JSON.parse(body).dig("repository", "full_name")
      rescue JSON::ParserError
        nil
      end

      unless repo_full_name
        head :bad_request
        return
      end

      owner, repo = repo_full_name.split("/", 2)
      project = Project.find_by(owner: owner, repo: repo)

      unless project&.webhook_secret.present?
        head :forbidden
        return
      end

      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", project.webhook_secret, body)}"

      unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)
        head :unauthorized
      end
    end
  end
end
