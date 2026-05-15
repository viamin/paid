# frozen_string_literal: true

module Api
  class GithubProxyController < ActionController::API
    include Api::ContainerAuthentication
    allow_chat_session_authentication!

    REVIEW_COMMENT_MARKER = "<!-- paid:code-review -->"
    REVIEW_HEADER = "## Code Review"
    STALE_REVIEW_DISMISSAL_MESSAGE = "Subsequent review found no remaining actionable issues."

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

      match = find_allowed_endpoint(request.method, path)

      unless match
        render json: { error: "Endpoint not allowed" }, status: :forbidden
        return
      end

      unless repo_matches?(project, match[:owner], match[:repo])
        render json: { error: "Repository mismatch" }, status: :forbidden
        return
      end

      github_token = project.github_token
      unless github_token&.active?
        render json: { error: "GitHub token not available" }, status: :service_unavailable
        return
      end

      forwarded_body = maybe_prepend_review_header(path, request.raw_post)
      response = proxy_to_github(path, github_authorization_token(path), forwarded_body)
      github_token.touch_last_used! unless use_review_bot_token?(path)

      if response.status >= 200 && response.status < 300
        track_issue_creation(path, response)
        track_review_creation(path, response)
      end

      render body: response.body, status: response.status,
             content_type: response.headers["content-type"] || "application/json"
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

    def github_authorization_token(path)
      project = authenticated_project
      return project.github_token.token unless use_review_bot_token?(path)

      Github::ReviewBotInstallationToken.new(
        repo_full_name: project.full_name
      ).fetch
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

    def review_url_for(pr_number, review_id)
      "https://github.com/#{authenticated_project.full_name}/pull/#{pr_number}#pullrequestreview-#{review_id}"
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
        ProviderSupport.provider_bot_usernames_for("paid_agent")
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
  end
end
