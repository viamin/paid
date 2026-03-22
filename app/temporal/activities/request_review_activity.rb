# frozen_string_literal: true

module Activities
  # Requests review from specified GitHub users on a pull request.
  # Checks existing pending reviewers first to avoid duplicate requests.
  # Handles 422 errors gracefully (e.g. Copilot not enabled on the repo).
  #
  # Bot reviewers (e.g. Copilot) use GraphQL requestReviews(botIds) because
  # the REST API silently fails for bot re-requests (returns 201 but does not
  # actually create the review request).
  class RequestReviewActivity < BaseActivity
    activity_name "RequestReview"

    COPILOT_LOGIN = "copilot"

    # Maps bot reviewer logins to a config key used to resolve their GraphQL
    # node ID at runtime (see #bot_node_id_for). Indirection allows the node
    # ID to be overridden per environment via Rails configuration.
    BOT_REVIEWERS = {
      COPILOT_LOGIN => :copilot
    }.freeze

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      reviewers = Array(input[:reviewers]).filter_map { |r| r.to_s.strip.presence }
      reviewers = reviewers.map(&:downcase).uniq
      return { requested: [] } if reviewers.empty?

      client = project.github_token.client

      already_pending = fetch_pending_reviewers(client, project, pr_number)
      needed = reviewers.reject { |r| already_pending.include?(r) }
      return { requested: [], already_pending: already_pending } if needed.empty?

      bots, humans = needed.partition { |r| BOT_REVIEWERS.key?(r) }

      request_human_reviews(client, project, pr_number, humans) if humans.any?
      request_bot_reviews(client, project, pr_number, bots) if bots.any?

      logger.info(
        message: "pr_review.review_requested",
        project_id: project.id,
        pr_number: pr_number,
        reviewers: needed
      )

      { requested: needed }
    rescue GithubClient::ApiError => e
      if e.status == 422
        logger.warn(
          message: "pr_review.request_review_unprocessable",
          project_id: input[:project_id],
          pr_number: pr_number,
          reviewers: reviewers,
          error: e.message
        )
        { requested: [], error: e.message }
      else
        raise
      end
    end

    private

    def request_human_reviews(client, project, pr_number, reviewers)
      client.request_pull_request_review(project.full_name, pr_number, reviewers: reviewers)
    end

    def request_bot_reviews(client, project, pr_number, reviewers)
      bot_node_ids = reviewers.map { |r| bot_node_id_for(BOT_REVIEWERS.fetch(r)) }
      client.request_bot_review(project.full_name, pr_number, bot_node_ids: bot_node_ids)
    end

    def bot_node_id_for(key)
      case key
      when :copilot
        Rails.configuration.x.copilot_bot_node_id.presence || "BOT_kgDOCnlnWA"
      else
        raise ArgumentError, "Unsupported bot reviewer key: #{key.inspect}"
      end
    end

    def fetch_pending_reviewers(client, project, pr_number)
      review_requests = client.pull_request_review_requests(project.full_name, pr_number)
      review_requests[:users].map(&:downcase)
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.fetch_pending_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
      []
    end
  end
end
