# frozen_string_literal: true

module Api
  class GithubProxyController < ActionController::API
    include Api::ContainerAuthentication

    # Allowlisted GitHub API endpoints (regex with named captures for owner/repo).
    ALLOWED_ENDPOINTS = [
      # Issues
      { method: "GET",   pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues\z} },
      { method: "GET",   pattern: %r{\Arepos/(?<owner>[^/]+)/(?<repo>[^/]+)/issues/(?<number>\d+)\z} },
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
      match = find_allowed_endpoint(request.method, path)

      unless match
        render json: { error: "Endpoint not allowed" }, status: :forbidden
        return
      end

      unless repo_matches?(match[:owner], match[:repo])
        render json: { error: "Repository mismatch" }, status: :forbidden
        return
      end

      github_token = @agent_run.project.github_token
      unless github_token&.active?
        render json: { error: "GitHub token not available" }, status: :service_unavailable
        return
      end

      response = proxy_to_github(path, github_token)
      github_token.touch_last_used!

      if response.status >= 200 && response.status < 300
        track_issue_creation(path, response)
        track_review_creation(path, response)
      end

      render body: response.body, status: response.status,
             content_type: response.headers["content-type"] || "application/json"
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

        return { owner: match_data[:owner], repo: match_data[:repo] }
      end

      nil
    end

    def repo_matches?(owner, repo)
      project_full_name = @agent_run.project.full_name
      "#{owner}/#{repo}".casecmp(project_full_name).zero?
    end

    def proxy_to_github(path, github_token)
      target_url = "https://api.github.com/#{path}"
      target_url = "#{target_url}?#{request.query_string}" if request.query_string.present?

      build_connection.run_request(
        request.method.downcase.to_sym,
        target_url,
        request.raw_post,
        forwarded_headers.merge(
          "Authorization" => "Bearer #{github_token.token}",
          "Accept" => "application/vnd.github+json"
        )
      )
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
      return unless request.method == "POST"
      # Only track for review-goal runs so non-review runs don't accidentally
      # set review_posted_at, which is used to verify review-goal completion.
      return unless @agent_run.review_goal?

      match = %r{\Arepos/[^/]+/[^/]+/pulls/(?<number>\d+)/reviews\z}.match(path)
      return unless match

      # Only track reviews posted on the run's target PR, not unrelated PRs.
      return unless @agent_run.source_pull_request_number == match[:number].to_i

      body = parse_response_body(response.body)
      return unless body.is_a?(Hash) && body["id"].present?
      return if @agent_run.review_posted_at.present?
      return unless body["html_url"].present?

      @agent_run.update!(review_posted_at: Time.current, review_url: body["html_url"])

      log_info("github_proxy.review_created",
        review_id: body["id"],
        review_url: body["html_url"])
    rescue => e
      log_error("github_proxy.track_review_failed", e.message)
    end

    def parse_response_body(body)
      return body if body.is_a?(Hash)

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def log_error(message, error)
      Rails.logger.error(
        message: message,
        agent_run_id: @agent_run&.id,
        error: error
      )
    end

    def log_info(message, **metadata)
      Rails.logger.info(
        message: message,
        agent_run_id: @agent_run&.id,
        **metadata
      )
    end
  end
end
