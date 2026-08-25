# frozen_string_literal: true

module Api
  class GithubProxyController < ActionController::API
    include Api::ContainerAuthentication
    allow_chat_session_authentication!

    # Review-body marker is owned by Github::ReviewMarker so the injection here
    # and the reconciliation consumer can't drift apart.
    REVIEW_COMMENT_MARKER = Github::ReviewMarker::PAID_REVIEW_MARKER
    REVIEW_HEADER = "## Code Review"
    STALE_REVIEW_DISMISSAL_MESSAGE = "Subsequent review found no remaining actionable issues."
    PENDING_REVIEW_ERROR_PATTERN = /one pending review per pull request/i
    GITHUB_ERROR_BODY_LOG_LIMIT = 2_000
    REVIEW_RECOVERY_WINDOW = 30.minutes

    # Allowlisted GitHub API endpoints (regex with named captures for owner/repo).
    ALLOWED_ENDPOINTS = [
      # Issues
      { method: "GET",   pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues\z} },
      { method: "GET",   pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues/(?<number>\d+)\z} },
      { method: "GET",   pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues/(?<number>\d+)/comments\z} },
      { method: "POST",  pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues\z} },
      { method: "PATCH", pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues/(?<number>\d+)\z} },
      { method: "POST",  pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues/(?<number>\d+)/comments\z} },
      { method: "POST",  pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues/(?<number>\d+)/labels\z} },
      # Pull requests (for review goal)
      { method: "GET",   pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/pulls/(?<number>\d+)\z} },
      { method: "GET",   pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/pulls/(?<number>\d+)/files\z} },
      { method: "POST",  pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/pulls/(?<number>\d+)/reviews\z} }
    ].freeze

    # GET/POST/PATCH /api/proxy/github/*path
    def proxy
      path = params[:path] || ""
      project = authenticated_project
      unless project
        render json: { error: "Project required" }, status: :forbidden
        return
      end

      # @spec ISSUE-ENHANCEMENT-006
      if enhancement_mutation?
        render json: { error: "Enhancement runs have read-only GitHub access" }, status: :forbidden
        return
      end

      if enhancement_read_out_of_scope?(path)
        render json: { error: "Enhancement runs can read only their associated issue details" }, status: :forbidden
        return
      end

      match = find_allowed_endpoint(request.method, path)

      unless match
        render json: { error: "Endpoint not allowed" }, status: :forbidden
        return
      end

      unless repo_matches?(project, match[:owner], match[:repo])
        render json: { error: "Repository mismatch" }, status: :forbidden
        return
      end

      github_token = project.github_credential
      unless github_token
        render json: { error: github_credential_unavailable_message(project) }, status: :service_unavailable
        return
      end

      forwarded_body = maybe_prepend_review_header(path, request.raw_post)
      authorization_token = github_authorization_token(path)
      response = forward_with_idempotent_recovery(path, authorization_token, forwarded_body, match: match)

      if review_creation_request?(path) && pending_review_conflict?(response)
        recovered = recover_from_pending_review(path, authorization_token, forwarded_body, match: match)
        response = recovered if recovered
      end

      project.github_token&.touch_last_used! unless use_review_bot_token?(path)

      if response.status >= 200 && response.status < 300
        track_issue_creation(path, response)
        track_review_creation(path, response)
        track_tdd_return_to_test_review(path, response)
      elsif response.status >= 400
        log_github_error_response(path, response)
      end

      render body: response.body, status: response.status,
             content_type: response.headers["content-type"] || "application/json"
    rescue Github::AppInstallation::ConfigurationError => e
      log_error("github_proxy.app_installation_token_failed", e.message)
      render json: { error: e.message }, status: :service_unavailable
    rescue Github::AppInstallation::Error => e
      log_error("github_proxy.app_installation_token_failed", e.message)
      render json: { error: e.message }, status: :bad_gateway
    rescue Github::ReviewBotInstallationToken::ConfigurationError => e
      log_error("github_proxy.review_bot_token_failed", e.message)
      render json: { error: e.message }, status: :service_unavailable
    rescue Github::ReviewBotInstallationToken::Error => e
      log_error("github_proxy.review_bot_token_failed", e.message)
      render json: { error: e.message }, status: :bad_gateway
    rescue Faraday::Error => e
      log_error("github_proxy.forward_failed", e.message)
      render json: { error: "Upstream request failed" }, status: :bad_gateway
    end

    private

    def enhancement_mutation?
      @agent_run&.enhance_issue_goal? && request.method != "GET"
    end

    def enhancement_read_out_of_scope?(path)
      return false unless @agent_run&.enhance_issue_goal? && request.get?

      issue_number = @agent_run.issue&.github_number
      issue_number.nil? || !path.match?(%r{\Arepos/[^/]+/[^/]+/issues/#{issue_number}\z})
    end

    def find_allowed_endpoint(http_method, path)
      ALLOWED_ENDPOINTS.each do |endpoint|
        next unless endpoint[:method] == http_method

        match_data = endpoint[:pattern].match(path)
        next unless match_data

        return match_data.named_captures.symbolize_keys
      end

      nil
    end

    def repo_matches?(project, owner, repo)
      project_full_name = project.full_name
      "#{owner}/#{repo}".casecmp(project_full_name).zero?
    end

    def proxy_to_github(path, authorization_token, body = request.raw_post)
      record_review_proxy_diagnostic(outcome: "attempted") if review_creation_request?(path)

      target_url = "https://api.github.com/#{path}"
      target_url = "#{target_url}?#{request.query_string}" if request.query_string.present?

      build_connection.run_request(
        request.method.downcase.to_sym,
        target_url,
        body,
        forwarded_headers.merge(
          "Authorization" => "Bearer #{authorization_token}",
          "Accept" => "application/vnd.github+json"
        )
      )
    end

    # Wrap the GitHub POST with idempotency-aware recovery for review creation
    # requests. The upstream review POST is not naturally idempotent, so a
    # timeout or connection failure can leave us uncertain whether GitHub
    # actually created the review. Listing PR reviews first lets us detect the
    # review if it did land and synthesize a success-equivalent response
    # instead of either silently retrying into a duplicate or surfacing a
    # bare 502 (#2778).
    def forward_with_idempotent_recovery(path, authorization_token, forwarded_body, match:)
      if review_creation_request?(path)
        forward_review_creation_with_idempotent_recovery(path, authorization_token, forwarded_body, match: match)
      else
        proxy_to_github(path, authorization_token, forwarded_body)
      end
    end

    def forward_review_creation_with_idempotent_recovery(path, authorization_token, forwarded_body, match:)
      proxy_to_github(path, authorization_token, forwarded_body)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      log_review_upstream_timeout(e)
      record_review_proxy_diagnostic(
        outcome: e.is_a?(Faraday::TimeoutError) ? "timeout" : "connection_failed",
        error_class: e.class.name,
        error_message: e.message
      )
      recover_or_retry_review(path, authorization_token, forwarded_body, match: match, error: e)
    end

    def log_review_upstream_timeout(error)
      Rails.logger.warn(
        message: "github_proxy.upstream_timeout",
        agent_run_id: @agent_run&.id,
        chat_session_id: @chat_session&.id,
        method: request.method,
        path: path_for_log,
        error_class: error.class.name,
        error: error.message.to_s.truncate(GITHUB_ERROR_BODY_LOG_LIMIT)
      )
    end

    def path_for_log
      @path_for_log ||= params[:path].to_s
    end

    def recover_or_retry_review(path, authorization_token, forwarded_body, match:, error:)
      existing = find_recent_paid_review(match, authorization_token, forwarded_body, request.raw_post)
      if existing
        log_review_recovered(existing, error)
        return synthetic_review_response(existing, match)
      end

      log_review_retry(match)
      retried = proxy_to_github(path, authorization_token, forwarded_body)
      log_review_retry_outcome(retried)
      retried
    rescue Faraday::Error => e
      log_error("github_proxy.final_failure",
        "path=#{path} error_class=#{e.class.name} message=#{e.message.to_s.truncate(GITHUB_ERROR_BODY_LOG_LIMIT)}")
      record_review_proxy_diagnostic(
        outcome: e.is_a?(Faraday::TimeoutError) ? "timeout" : "connection_failed",
        error_class: e.class.name,
        error_message: e.message
      )
      raise
    end

    def log_review_recovered(existing, error)
      Rails.logger.info(
        message: "github_proxy.recovered_existing_review",
        agent_run_id: @agent_run&.id,
        chat_session_id: @chat_session&.id,
        review_id: existing["id"],
        review_state: existing["state"],
        upstream_error_class: error.class.name
      )
    end

    def log_review_retry(match)
      Rails.logger.info(
        message: "github_proxy.retry",
        agent_run_id: @agent_run&.id,
        chat_session_id: @chat_session&.id,
        path: "repos/#{match[:owner]}/#{match[:repo]}/pulls/#{match[:number]}/reviews"
      )
    end

    def log_review_retry_outcome(response)
      Rails.logger.info(
        message: response.success? ? "github_proxy.retry_succeeded" : "github_proxy.retry_failed",
        agent_run_id: @agent_run&.id,
        chat_session_id: @chat_session&.id,
        status: response.status
      )
    end

    # Build a Faraday response-like object from a review we recovered by listing
    # the PR's existing reviews. The downstream tracking code reads
    # response.status / response.body and passes them on, so we just need a
    # minimal Hash-shaped payload that responds to those interfaces.
    def synthetic_review_response(review, match)
      body = {
        "id" => review["id"],
        "state" => review["state"],
        "html_url" => review["html_url"] ||
          review_url_for(match[:number], review["id"]),
        "body" => review["body"],
        "submitted_at" => review["submitted_at"],
        "user" => review["user"]
      }.compact.to_json

      SyntheticResponse.new(status: 200, body: body)
    end

    def github_authorization_token(path)
      project = authenticated_project
      return Github::ReviewBotInstallationToken.new(
        repo_full_name: project.full_name
      ).fetch if use_review_bot_token?(path)

      project.github_credential
    end

    def github_credential_unavailable_message(project)
      if project.github_installation_id.present? || project.github_installation.present?
        "GitHub App installation not available"
      else
        "GitHub token not available"
      end
    end

    def use_review_bot_token?(path)
      @agent_run&.review_goal? &&
        authenticated_project&.review_method_enabled?("paid_agent") &&
        request.method == "POST" &&
        %r{\Arepos/[^/]+/[^/]+/pulls/\d+/reviews\z}.match?(path)
    end

    def maybe_prepend_review_header(path, raw_body)
      return raw_body unless review_creation_request?(path)

      body = parse_request_body(raw_body)
      return raw_body unless body["body"].is_a?(String)
      return raw_body if body["body"].include?(REVIEW_COMMENT_MARKER)

      body["body"] = "#{REVIEW_COMMENT_MARKER}\n#{REVIEW_HEADER}\n\n#{body["body"]}"
      body.to_json
    end

    def review_creation_request?(path)
      @agent_run&.review_goal? &&
        request.method == "POST" &&
        %r{\Arepos/[^/]+/[^/]+/pulls/\d+/reviews\z}.match?(path)
    end

    def build_connection
      Faraday.new do |f|
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def forwarded_headers
      %w[Content-Type].each_with_object({}) do |header, hash|
        value = request.headers[header]
        hash[header] = value if value.present?
      end
    end

    def track_issue_creation(path, response)
      return unless @agent_run
      return unless request.method == "POST"
      return unless %r{\Arepos/[^/]+/[^/]+/issues\z}.match?(path)

      body = parse_response_body(response.body)
      return unless body.is_a?(Hash) && body["number"].present?

      @agent_run.update!(
        created_issue_url: body["html_url"],
        created_issue_number: body["number"]
      )

      log_info("github_proxy.issue_created",
        issue_number: body["number"],
        issue_url: body["html_url"])
    rescue => e
      log_error("github_proxy.track_issue_failed", e.message)
    end

    def track_review_creation(path, response)
      return unless @agent_run
      return unless request.method == "POST"
      return unless @agent_run.review_goal?

      match = %r{\Arepos/[^/]+/[^/]+/pulls/(?<number>\d+)/reviews\z}.match(path)
      return unless match

      # Only track reviews posted on the run's target PR, not unrelated PRs.
      return unless @agent_run.source_pull_request_number == match[:number].to_i

      body = parse_response_body(response.body)
      return unless body.is_a?(Hash) && body["id"].present?

      record_review_proxy_diagnostic(outcome: "succeeded")

      if @agent_run.review_posted_at.blank? || @agent_run.review_url.blank?
        review_url = body["html_url"].presence || review_url_for(match[:number], body["id"])
        @agent_run.update!(
          review_posted_at: @agent_run.review_posted_at || Time.current,
          review_url: review_url
        )

        log_info("github_proxy.review_created",
          review_id: body["id"],
          review_url: review_url)
      end

      warn_if_missing_inline_comments(body)
      dismiss_stale_changes_requested_reviews(match, body)
    rescue => e
      log_error("github_proxy.track_review_failed", e.message)
    end

    def track_tdd_return_to_test_review(path, response)
      return unless @agent_run&.tdd_test_fixing_phase?

      match = %r{\Arepos/[^/]+/[^/]+/issues/(?<number>\d+)(?:/labels)?\z}.match(path)
      return unless match
      return unless @agent_run.source_pull_request_number == match[:number].to_i

      body = parse_response_body(response.body)
      labels = extract_issue_labels(body)
      return unless labels

      updated = Tdd::ReturnToTestReview.record_from_label_state(agent_run: @agent_run, labels: labels)
      return unless updated

      log_info("github_proxy.tdd_return_to_test_review_recorded", pr_number: match[:number].to_i)
    rescue => e
      log_error("github_proxy.track_tdd_return_to_test_review_failed", e.message)
    end

    def extract_issue_labels(body)
      return body if body.is_a?(Array)
      return body["labels"] if body.is_a?(Hash) && body["labels"].is_a?(Array)

      nil
    end

    def review_url_for(pr_number, review_id)
      "https://github.com/#{authenticated_project.full_name}/pull/#{pr_number}#pullrequestreview-#{review_id}"
    end

    # Records the latest known outcome of a review-creation proxy POST on the
    # agent run so CompleteReviewGoalActivity can explain a missing-review
    # failure without digging through raw logs (#2779). Each call overwrites
    # the prior snapshot — only the most recent outcome matters for
    # diagnosing why a run finished without a tracked review.
    def record_review_proxy_diagnostic(outcome:, http_status: nil, error_class: nil, error_message: nil)
      return unless @agent_run

      @agent_run.update_column(:review_proxy_diagnostics, {
        "outcome" => outcome,
        "http_status" => http_status,
        "error_class" => error_class,
        "error_message" => error_message.presence&.to_s&.truncate(GITHUB_ERROR_BODY_LOG_LIMIT),
        "recorded_at" => Time.current.iso8601
      }.compact)
    rescue => e
      log_error("github_proxy.review_diagnostic_record_failed", e.message)
    end

    # GitHub rejects POST /pulls/N/reviews with 422 if the authenticated user
    # already has a PENDING review on the PR. A prior interrupted review run
    # can leave one behind, causing every subsequent review attempt to fail
    # the same way (#2324).
    def pending_review_conflict?(response)
      return false unless response.status == 422

      body = parse_response_body(response.body)
      return false unless body.is_a?(Hash)

      errors = Array(body["errors"]).flat_map do |err|
        err.is_a?(Hash) ? err.values_at("message", "code") : [ err ]
      end
      errors << body["message"]
      errors.any? { |msg| msg.to_s.match?(PENDING_REVIEW_ERROR_PATTERN) }
    end

    # Find the bot's PENDING review on the target PR and DELETE it, then
    # retry the original POST exactly once. Returns the retried response on
    # success, or nil if recovery wasn't possible (in which case the caller
    # keeps the original 422).
    def recover_from_pending_review(path, authorization_token, forwarded_body, match:)
      pending_id = find_pending_review_id(match[:owner], match[:repo], match[:number], authorization_token)
      return nil unless pending_id

      delete_response = github_api_call(:delete,
        "repos/#{match[:owner]}/#{match[:repo]}/pulls/#{match[:number]}/reviews/#{pending_id}",
        authorization_token, nil)
      unless delete_response.status.between?(200, 299)
        log_error("github_proxy.pending_review_delete_failed",
          "status=#{delete_response.status} pending_review_id=#{pending_id}")
        return nil
      end

      log_info("github_proxy.pending_review_recovered",
        pending_review_id: pending_id,
        pr_number: match[:number].to_i)

      proxy_to_github(path, authorization_token, forwarded_body)
    rescue Faraday::Error => e
      log_error("github_proxy.pending_review_recovery_failed", e.message)
      nil
    end

    def find_pending_review_id(owner, repo, number, authorization_token)
      list_path = "repos/#{owner}/#{repo}/pulls/#{number}/reviews?per_page=100"
      response = github_api_call(:get, list_path, authorization_token, nil)
      return nil unless response.status.between?(200, 299)

      reviews = parse_response_body(response.body)
      return nil unless reviews.is_a?(Array)

      pending = reviews.find { |r| r.is_a?(Hash) && r["state"].to_s.casecmp("PENDING").zero? }
      pending&.dig("id")
    end

    def github_api_call(method, path, authorization_token, body)
      target_url = "https://api.github.com/#{path}"
      build_connection.run_request(
        method, target_url, body,
        "Authorization" => "Bearer #{authorization_token}",
        "Accept" => "application/vnd.github+json"
      )
    end

    def log_github_error_response(path, response)
      Rails.logger.warn(
        message: "github_proxy.upstream_error",
        agent_run_id: @agent_run&.id,
        chat_session_id: @chat_session&.id,
        method: request.method,
        path: path,
        status: response.status,
        body: response.body.to_s.truncate(GITHUB_ERROR_BODY_LOG_LIMIT)
      )

      return unless review_creation_request?(path)

      record_review_proxy_diagnostic(
        outcome: "upstream_error",
        http_status: response.status,
        error_message: response.body
      )
    end

    def warn_if_missing_inline_comments(response_body)
      request_body = parse_request_body(request.raw_post)
      comment_count = Array(request_body["comments"]).length

      return unless comment_count.zero?
      return unless non_clean_review?(request_body, response_body)

      Rails.logger.warn(
        message: "github_proxy.review_missing_inline_comments",
        agent_run_id: @agent_run.id,
        review_id: response_body["id"],
        comment_count: comment_count
      )
    end

    # When a new review is posted that does NOT request changes, dismiss any
    # previous CHANGES_REQUESTED reviews from the paid-code-reviewer bot.
    # Without this, stale change requests block PR merging even after the
    # issues have been addressed.
    def dismiss_stale_changes_requested_reviews(path_match, new_review)
      return if review_state(new_review["state"]) == "CHANGES_REQUESTED"

      project = authenticated_project
      return unless project&.review_method_enabled?("paid_agent")
      return unless Github::ReviewBotInstallationToken.configured?
      bot_logins = project.enabled_review_bot_logins &
        RunnerSupport.runner_bot_usernames_for("paid_agent")
      return if bot_logins.empty?
      return if path_match[:number].blank? || new_review["id"].blank?
      pr_number = path_match[:number].to_i
      new_review_id = new_review["id"].to_i
      return if pr_number.zero? || new_review_id.zero?

      bot_client = GithubClient.new(
        token: Github::ReviewBotInstallationToken.new(
          repo_full_name: project.full_name
        ).fetch
      )

      reviews = Array(bot_client.pull_request_reviews(project.full_name, pr_number))
      stale = reviews.select do |r|
        review_state(review_attribute(r, :state)) == "CHANGES_REQUESTED" &&
          bot_logins.include?(review_attribute(r, :user_login).to_s.downcase) &&
          stale_review?(r, new_review)
      end

      stale.each do |review|
        review_id = review_attribute(review, :id).to_i
        next if review_id.zero?

        bot_client.dismiss_pull_request_review(
          project.full_name, pr_number, review_id,
          message: STALE_REVIEW_DISMISSAL_MESSAGE
        )
        log_info("github_proxy.dismissed_stale_review",
          review_id: review_id,
          pr_number: pr_number)
      end
    rescue => e
      log_error("github_proxy.dismiss_stale_reviews_failed", e.message)
    end

    def parse_response_body(body)
      return body if body.is_a?(Hash)

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def parse_request_body(body)
      return {} if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def non_clean_review?(request_body, response_body)
      return false if clean_review_event?(request_body)
      return false if clean_review_state?(response_body)
      return false if clean_review_body?(response_body["body"])

      true
    end

    def clean_review_event?(request_body)
      request_body&.dig("event").to_s.casecmp("APPROVE").zero?
    end

    def clean_review_state?(response_body)
      response_body["state"].to_s.casecmp("APPROVED").zero?
    end

    def clean_review_body?(body)
      body.to_s.include?("<!-- paid-review-clean -->")
    end

    def review_state(value)
      value.to_s.upcase
    end

    def review_attribute(review, key)
      direct_value = review[key] || review[key.to_s]
      return direct_value if direct_value.present?
      return unless key.to_sym == :user_login

      user = review[:user] || review["user"]
      user&.dig(:login) || user&.dig("login")
    end

    def stale_review?(review, new_review)
      review_submitted_at = review_submitted_at(review)
      new_review_submitted_at = review_submitted_at(new_review)
      if review_submitted_at && new_review_submitted_at
        return review_submitted_at < new_review_submitted_at
      end

      review_id = review_attribute(review, :id).to_i
      return false if review_id.zero?

      new_review_id = review_attribute(new_review, :id).to_i
      return false if new_review_id.zero?

      review_id < new_review_id
    end

    def review_submitted_at(review)
      value = review_attribute(review, :submitted_at)
      return value if value.is_a?(Time)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def log_error(message, error)
      Rails.logger.error(
        message: message,
        agent_run_id: @agent_run&.id,
        chat_session_id: @chat_session&.id,
        error: error
      )
    end

    def log_info(message, **metadata)
      Rails.logger.info(
        message: message,
        agent_run_id: @agent_run&.id,
        chat_session_id: @chat_session&.id,
        **metadata
      )
    end

    # List PR reviews and pick one that looks like the review this run was
    # trying to post: the Paid marker is present, or the actor matches the
    # authenticated GitHub user, or the review body matches the body the
    # proxy was about to send. Time-windowing against the agent run keeps us
    # from claiming a stale review posted by a previous attempt.
    def find_recent_paid_review(match, authorization_token, forwarded_body, raw_body)
      list_path = "repos/#{match[:owner]}/#{match[:repo]}/pulls/#{match[:number]}/reviews?per_page=100"
      response = github_api_call(:get, list_path, authorization_token, nil)
      return nil unless response.status.between?(200, 299)

      reviews = parse_response_body(response.body)
      return nil unless reviews.is_a?(Array)

      forwarded_marker_body = parse_review_body(forwarded_body)
      raw_body_value = parse_review_body(raw_body)
      candidates = reviews.select do |review|
        review.is_a?(Hash) && recovery_match?(review, forwarded_marker_body, raw_body_value)
      end
      candidates.max_by { |r| review_submitted_at(r) || Time.at(0) }
    rescue Github::AppInstallation::Error, Github::ReviewBotInstallationToken::Error,
           Faraday::Error => e
      log_error("github_proxy.review_recovery_list_failed", e.message)
      nil
    end

    def parse_review_body(body)
      parse_request_body(body)["body"]
    end

    def recovery_match?(review, forwarded_marker_body, raw_body)
      return false if review["state"].to_s.casecmp("PENDING").zero?
      return false unless within_recovery_window?(review)

      # Marker match (strong): the GitHub-stored review body includes the Paid
      # marker, which the proxy always prepends to review-goal POST bodies. If
      # the stored body includes it, this review was posted by the proxy.
      return true if recovery_marker_match?(review)

      # Body match against the forwarded body (also strong, catches the case
      # where the agent happens to include the marker in their submitted body
      # and the proxy didn't need to prepend).
      return true if recovery_body_match?(review, forwarded_marker_body)

      # Body match against the original raw body (weaker; useful when the
      # review was posted without the marker — e.g., directly from the runner
      # bypassing the proxy).
      recovery_body_match?(review, raw_body)
    end

    def within_recovery_window?(review)
      submitted_at = review_submitted_at(review)
      return true unless submitted_at
      return true unless @agent_run

      lower = (@agent_run.started_at || @agent_run.created_at) - REVIEW_RECOVERY_WINDOW
      upper = Time.current + REVIEW_RECOVERY_WINDOW
      submitted_at.between?(lower, upper)
    end

    def recovery_marker_match?(review)
      review["body"].to_s.include?(REVIEW_COMMENT_MARKER)
    end

    def recovery_body_match?(review, submitted_body)
      return false if submitted_body.blank?

      review["body"].to_s.strip == submitted_body.to_s.strip
    end
  end

  # Minimal Faraday::Response-shaped object used to surface a recovered review
  # back through the proxy's tracking pipeline without re-running the upstream
  # request. The controller only reads .status, .body, and .headers.
  class SyntheticResponse
    attr_reader :status, :body, :headers

    def initialize(status:, body:, headers: { "Content-Type" => "application/json" })
      @status = status
      @body = body
      @headers = headers
    end

    def success?
      status.is_a?(Integer) && status >= 200 && status < 300
    end

    def [](key)
      headers[key.to_s] || headers[key.to_sym]
    end
  end
end
