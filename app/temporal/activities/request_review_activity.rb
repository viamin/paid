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
  # bot-reviewer chain from the project's enabled review methods via
  # Project#review_bot_request_chain. The first reviewer in the chain is the
  # primary; if it returns a 422 (e.g. Copilot rate-limited or not enabled
  # on the repo), the activity automatically falls through to the next bot
  # in the chain. Pass an explicit empty array to request no reviewers.
  #
  # The result includes a :fallback_used flag (true when the primary bot
  # was skipped in favor of a later one in the chain) and the per-bot
  # :primary_bot / :fallback_bots metadata so callers can surface which
  # provider actually got the review request.
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

      bot_chain, humans = partition_bot_chain_and_humans(needed)
      requested = []

      if humans.any?
        request_human_reviews(client, project, pr_number, humans)
        requested.concat(humans)
      end

      bot_result = request_bots_with_fallback(client, project, pr_number, bot_chain)
      requested.concat(bot_result[:requested])

      logger.info(
        message: "pr_review.review_requested",
        project_id: project.id,
        pr_number: pr_number,
        reviewers: requested,
        primary_bot: bot_result[:primary_bot],
        fallback_used: bot_result[:fallback_used]
      ) if requested.any?

      result = { requested: requested }
      result[:primary_bot] = bot_result[:primary_bot] if bot_result[:primary_bot]
      result[:fallback_used] = bot_result[:fallback_used] if bot_result[:fallback_used]
      result[:fallback_bots] = bot_result[:fallback_bots] if bot_result[:fallback_bots].any?
      result[:bot_errors] = bot_result[:errors] if bot_result[:errors].any?
      result
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
    # nil, fall back to the project's enabled review bot chain so workflows
    # do not need to hardcode per-project policy. Using the full chain
    # (instead of just the primary bot) lets the activity skip past a
    # rate-limited primary to a configured secondary in one execution.
    def resolve_reviewers(input, project)
      raw = input[:reviewers]
      source = raw.nil? ? Array(project.review_bot_request_chain) : Array(raw)
      source.filter_map { |r| r.to_s.strip.presence&.downcase }.uniq
    end

    def request_human_reviews(client, project, pr_number, reviewers)
      client.request_pull_request_review(project.full_name, pr_number, reviewers: reviewers)
    end

    # Splits the needed reviewer list into an ordered bot chain (preserving
    # caller order so the first bot is the primary attempt) and a separate
    # human-reviewer list. Non-recognized logins fall through to the human
    # branch, matching the legacy behavior.
    def partition_bot_chain_and_humans(needed)
      bots, humans = needed.partition { |r| bot_reviewer?(r) }
      [ bots, humans ]
    end

    def bot_reviewer?(login)
      BOT_REVIEWERS.key?(login) || COMMENT_TRIGGER_REVIEWERS.key?(login)
    end

    # Iterates the bot chain in order, attempting each one until one
    # resolves the request (a fresh post, an idempotent no-op, or a
    # transient skip) or the chain is exhausted by 422 failures. Falls
    # through only on 422 (e.g. the bot is rate-limited or not enabled for
    # the repo) so a configured secondary bot can pick up the review
    # request automatically. Idempotent and transient-error outcomes are
    # treated as terminal for this cycle so the secondary bot is not
    # spammed when the primary already has an outstanding request or is
    # temporarily inaccessible.
    def request_bots_with_fallback(client, project, pr_number, bot_chain)
      result = {
        requested: [],
        primary_bot: bot_chain.first,
        fallback_used: false,
        fallback_bots: [],
        errors: {}
      }
      return result if bot_chain.empty?

      bot_chain.each_with_index do |bot, index|
        status, error_message = attempt_bot_reviewer(client, project, pr_number, bot)
        case status
        when :posted
          result[:requested] << bot
          result[:fallback_used] = index.positive?
          result[:fallback_bots] = bot_chain[1..index] if index.positive?
          break
        when :already_requested, :transient_skip
          break
        when :failed_with_fallback
          result[:errors][bot] = error_message if error_message
          logger.info(
            message: "pr_review.bot_review_falling_back",
            project_id: project.id,
            pr_number: pr_number,
            bot: bot,
            remaining: bot_chain[(index + 1)..]
          ) if index < bot_chain.size - 1
        end
      end

      result
    end

    # Dispatches a single bot to the appropriate request mechanism (GraphQL
    # bot review for Copilot-style bots, @-mention comment trigger for
    # Codex-style bots). Returns one of:
    #   - +[:posted, nil]+ — fresh request was issued
    #   - +[:already_requested, nil]+ — outstanding request already exists
    #   - +[:transient_skip, nil]+ — temporary error; do not fall through
    #   - +[:failed_with_fallback, message]+ — 422; try the next bot
    def attempt_bot_reviewer(client, project, pr_number, bot)
      if BOT_REVIEWERS.key?(bot)
        request_single_bot_review(client, project, pr_number, bot)
      elsif COMMENT_TRIGGER_REVIEWERS.key?(bot)
        post_single_comment_trigger(client, project, pr_number, bot)
      else
        [ :failed_with_fallback, nil ]
      end
    end

    def request_single_bot_review(client, project, pr_number, bot)
      bot_node_ids = [ bot_node_id_for(BOT_REVIEWERS.fetch(bot)) ]
      client.request_bot_review(project.full_name, pr_number, bot_node_ids: bot_node_ids)
      [ :posted, nil ]
    rescue GithubClient::ApiError => e
      if e.status == 422
        logger.warn(
          message: "pr_review.bot_review_unprocessable",
          project_id: project.id,
          pr_number: pr_number,
          reviewers: [ bot ],
          error: e.message
        )
        [ :failed_with_fallback, e.message ]
      else
        raise
      end
    end

    # Posts an @-mention comment (e.g. "@codex review") for a bot that does
    # not honor programmatic review requests on draft PRs. Idempotent per
    # HEAD SHA: embeds a marker in the posted comment and treats an already
    # present marker as a successful prior trigger.
    #
    # Returns one of:
    #   - +[:posted, nil]+ — a fresh trigger comment was posted.
    #   - +[:already_requested, nil]+ — the marker for the current HEAD is
    #     already present, or +comment_marker_present?+ returned true as
    #     its safe default after a transient fetch failure. In both cases
    #     we treat the prior trigger as outstanding and do NOT fall through
    #     to an alternate provider, matching the legacy behavior of the
    #     batched +post_comment_triggers+ method.
    #   - +[:transient_skip, nil]+ — the PR HEAD could not be fetched, so we
    #     cannot scope a marker to it. Skip without falling through; the
    #     next poll will retry.
    #   - +[:failed_with_fallback, message]+ — the bot rejected the request
    #     with 422; try the next bot in the chain.
    def post_single_comment_trigger(client, project, pr_number, bot)
      head_sha = fetch_pr_head_sha(client, project, pr_number)
      return [ :transient_skip, nil ] unless head_sha

      marker = "#{COMMENT_TRIGGER_MARKER_PREFIX}: #{head_sha}"

      if comment_marker_present?(client, project, pr_number, marker)
        logger.info(
          message: "pr_review.comment_trigger_skipped",
          project_id: project.id,
          pr_number: pr_number,
          reviewers: [ bot ],
          head_sha: head_sha,
          reason: "already_triggered_for_head"
        )
        return [ :already_requested, nil ]
      end

      mention = COMMENT_TRIGGER_REVIEWERS.fetch(bot)
      body = "<!-- #{marker} -->\n#{mention}"
      client.add_comment(project.full_name, pr_number, body)
      [ :posted, nil ]
    rescue GithubClient::ApiError => e
      if e.status == 422
        logger.warn(
          message: "pr_review.comment_trigger_unprocessable",
          project_id: project.id,
          pr_number: pr_number,
          reviewer: bot,
          error: e.message
        )
        [ :failed_with_fallback, e.message ]
      else
        raise
      end
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
