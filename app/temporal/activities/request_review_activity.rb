# frozen_string_literal: true

module Activities
  # Requests review from specified GitHub users on a pull request.
  # Checks existing pending reviewers first to avoid duplicate requests.
  # Handles 422 errors gracefully (e.g. Copilot not enabled on the repo).
  #
  # Dispatches by reviewer category:
  #   - Humans: REST requestReviewers endpoint.
  #   - Bot reviewers that honor programmatic review requests (e.g. Copilot)
  #     use GraphQL requestReviews(botIds). The REST API silently fails for
  #     bot re-requests (returns 201 but does not actually create the review
  #     request).
  #   - Bot reviewers that do NOT honor programmatic review requests on draft
  #     PRs (e.g. Codex) are triggered by posting an @-mention comment on the
  #     PR. The posted comment embeds a marker scoped to the current HEAD SHA
  #     so re-invocations on the same commit are idempotent.
  #
  # When the :reviewers input key is omitted or nil, the activity resolves the
  # reviewer from the project's enabled review methods via
  # Project#review_bot_request_login. Pass an explicit empty array to request
  # no reviewers.
  class RequestReviewActivity < BaseActivity
    activity_name "RequestReview"

    COPILOT_LOGIN = "copilot"
    CODEX_LOGIN = "chatgpt-codex-connector"

    # Default GraphQL node ID for the copilot-pull-request-reviewer bot.
    # Override per environment via config.x.copilot_bot_node_id.
    # To verify: gh api users/copilot-pull-request-reviewer%5Bbot%5D --jq '.node_id'
    COPILOT_DEFAULT_NODE_ID = "BOT_kgDOCnlnWA"

    # Maps bot reviewer logins to a config key used to resolve their GraphQL
    # node ID at runtime (see #bot_node_id_for). Indirection allows the node
    # ID to be overridden per environment via Rails configuration.
    BOT_REVIEWERS = {
      COPILOT_LOGIN => :copilot
    }.freeze

    # Maps review-bot logins that do not accept GraphQL review requests on
    # draft PRs to the @-mention string that triggers a review from them.
    COMMENT_TRIGGER_REVIEWERS = {
      CODEX_LOGIN => "@codex review"
    }.freeze

    # Machine marker prefix embedded in Paid-authored trigger comments. The
    # full marker is "<PREFIX>: <head_sha>", so idempotency checks can skip
    # re-posting when a marker for the current HEAD is already present.
    COMMENT_TRIGGER_MARKER_PREFIX = "paid-review-trigger"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      reviewers = resolve_reviewers(input, project)
      return { requested: [] } if reviewers.empty?

      client = project.github_token.client

      already_pending = fetch_pending_reviewers(client, project, pr_number)
      needed = reviewers.reject { |r| already_pending.include?(r) }
      return { requested: [], already_pending: already_pending } if needed.empty?

      comment_triggers, remaining = needed.partition { |r| COMMENT_TRIGGER_REVIEWERS.key?(r) }
      bots, humans = remaining.partition { |r| BOT_REVIEWERS.key?(r) }
      requested = []

      if humans.any?
        request_human_reviews(client, project, pr_number, humans)
        requested.concat(humans)
      end

      if bots.any? && request_bot_reviews(client, project, pr_number, bots)
        requested.concat(bots)
      end

      if comment_triggers.any?
        requested.concat(post_comment_triggers(client, project, pr_number, comment_triggers))
      end

      logger.info(
        message: "pr_review.review_requested",
        project_id: project.id,
        pr_number: pr_number,
        reviewers: requested
      ) if requested.any?

      { requested: requested }
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

    # Explicit reviewers input takes precedence; when the key is omitted or
    # nil, fall back to the project's enabled review bot so workflows do not
    # need to hardcode per-project policy.
    def resolve_reviewers(input, project)
      raw = input[:reviewers]
      source = raw.nil? ? Array(project.review_bot_request_login) : Array(raw)
      source.filter_map { |r| r.to_s.strip.presence&.downcase }.uniq
    end

    def request_human_reviews(client, project, pr_number, reviewers)
      client.request_pull_request_review(project.full_name, pr_number, reviewers: reviewers)
    end

    def request_bot_reviews(client, project, pr_number, reviewers)
      bot_node_ids = reviewers.map { |r| bot_node_id_for(BOT_REVIEWERS.fetch(r)) }
      client.request_bot_review(project.full_name, pr_number, bot_node_ids: bot_node_ids)
      true
    rescue GithubClient::ApiError => e
      if e.status == 422
        logger.warn(
          message: "pr_review.bot_review_unprocessable",
          project_id: project.id,
          pr_number: pr_number,
          reviewers: reviewers,
          error: e.message
        )
        false
      else
        raise
      end
    end

    # Posts an @-mention comment (e.g. "@codex review") for each bot that
    # does not honor programmatic review requests on draft PRs. Idempotent
    # per HEAD SHA: embeds a marker in the posted comment and skips posting
    # if a marker for the current HEAD is already present on the PR.
    def post_comment_triggers(client, project, pr_number, reviewers)
      head_sha = fetch_pr_head_sha(client, project, pr_number)
      return [] unless head_sha

      marker = "#{COMMENT_TRIGGER_MARKER_PREFIX}: #{head_sha}"

      if comment_marker_present?(client, project, pr_number, marker)
        logger.info(
          message: "pr_review.comment_trigger_skipped",
          project_id: project.id,
          pr_number: pr_number,
          reviewers: reviewers,
          head_sha: head_sha,
          reason: "already_triggered_for_head"
        )
        return []
      end

      posted = []
      reviewers.each do |reviewer|
        mention = COMMENT_TRIGGER_REVIEWERS.fetch(reviewer)
        body = "<!-- #{marker} -->\n#{mention}"
        client.add_comment(project.full_name, pr_number, body)
        posted << reviewer
      rescue GithubClient::ApiError => e
        if e.status == 422
          logger.warn(
            message: "pr_review.comment_trigger_unprocessable",
            project_id: project.id,
            pr_number: pr_number,
            reviewer: reviewer,
            error: e.message
          )
        else
          raise
        end
      end
      posted
    end

    # Returns true when a trigger marker for the current HEAD is already
    # present on the PR in a comment authored by Paid (this token's own
    # identity), false when definitely absent. Returns true on fetch
    # failure as a safe default: if we cannot verify whether a trigger has
    # already been posted, skip posting this cycle to avoid spamming comments
    # on every poll while a transient GitHub API error persists. The marker
    # will be re-checked on the next invocation.
    #
    # Author-gating matters because the marker format is derivable from the
    # public PR head SHA. Without it, a third-party comment containing the
    # marker string (accidentally or maliciously) would suppress the trigger
    # and strand the PR. When the authenticated identity cannot be resolved,
    # fall back to matching any comment so the safe "skip if unsure" default
    # still applies.
    def comment_marker_present?(client, project, pr_number, marker)
      paid_login = client.authenticated_login
      # Use the bounded recent-comments endpoint (100 most recent, one API
      # call) instead of auto-paginating the full comment history. The
      # trigger marker we posted has to be among the recent comments if it
      # exists at all — Paid polls PRs frequently enough that a matching
      # marker for the current HEAD SHA would be very recent — and long-
      # lived PRs can accumulate hundreds of comments, which previously
      # risked rate-limit exhaustion on every idempotency check.
      comments = client.recent_issue_comments(project.full_name, pr_number)
      comments.any? do |c|
        next false unless c.body.to_s.include?(marker)
        next true if paid_login.nil?

        c.user&.login&.downcase == paid_login
      end
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.fetch_comments_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
      true
    end

    def fetch_pr_head_sha(client, project, pr_number)
      pr = client.pull_request(project.full_name, pr_number)
      pr&.head&.sha
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.fetch_pr_head_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
      nil
    end

    def bot_node_id_for(key)
      case key
      when :copilot
        Rails.configuration.x.copilot_bot_node_id.presence || COPILOT_DEFAULT_NODE_ID
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
