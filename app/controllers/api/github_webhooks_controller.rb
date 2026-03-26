# frozen_string_literal: true

module Api
  # Receives GitHub webhook events for PR reviews.
  # Verifies the webhook signature using the project's webhook_secret,
  # then dispatches to the appropriate feedback collection service.
  #
  # Supported events:
  #   - pull_request_review: Maps approved/changes_requested/commented to quality scores
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

      head :ok
    end

    def find_agent_run(pr_number)
      return nil unless @project && pr_number

      # Only record feedback for successful (completed) runs to avoid skewing
      # metrics — mirrors the guard in HumanFeedbackCollectionJob#perform.
      @project.agent_runs
        .where(pull_request_number: pr_number, status: "completed")
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
