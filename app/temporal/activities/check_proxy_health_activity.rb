# frozen_string_literal: true

require "uri"
require "net/http"

module Activities
  # Checks whether the Rails credential proxy is healthy and reachable.
  #
  # Called before proxy-dependent operations (clone, push) in the
  # AgentExecutionWorkflow. When the proxy is down (e.g. due to a
  # PendingMigration crash), this activity performs a single health check
  # and raises a retryable error if unhealthy. The workflow's retry policy
  # manages backoff and total wait time, keeping the activity worker thread
  # free between attempts.
  #
  # Uses the Rails health check endpoint (/up) which returns 200 when
  # the app boots without exceptions.
  class CheckProxyHealthActivity < BaseActivity
    activity_name "CheckProxyHealth"

    # Maximum time (used by the workflow's schedule_to_close_timeout) to wait
    # for the proxy to become healthy before giving up.
    MAX_WAIT_SECONDS = 600
    # Initial interval between health check polls (used by workflow retry policy).
    INITIAL_POLL_INTERVAL = 5
    # Maximum interval between polls (used by workflow retry policy).
    MAX_POLL_INTERVAL = 30
    # Backoff multiplier between polls (used by workflow retry policy).
    BACKOFF_MULTIPLIER = 2

    def execute(input)
      agent_run_id = input[:agent_run_id]
      proxy_url = proxy_base_url(agent_run_id)

      return { healthy: true } if proxy_url.blank?

      health_url = build_health_url(proxy_url)

      if healthy?(health_url)
        logger.info(
          message: "agent_execution.proxy_health_check_passed",
          agent_run_id: agent_run_id
        )

        { healthy: true }
      else
        logger.warn(
          message: "agent_execution.proxy_health_check_unhealthy",
          agent_run_id: agent_run_id,
          proxy_url: proxy_url
        )

        # Retryable error — Temporal's retry policy will handle backoff.
        # When retries are exhausted (schedule_to_close_timeout exceeded),
        # Temporal will surface this as a timeout failure which the workflow
        # catches and converts to ProxyUnavailable.
        raise Temporalio::Error::ApplicationError.new(
          "Credential proxy unavailable",
          type: "ProxyUnhealthy",
          non_retryable: false
        )
      end
    end

    private

    def proxy_base_url(agent_run_id)
      # Fail fast if the agent run doesn't exist — proceeding with a missing
      # run would incorrectly treat the proxy as healthy.
      AgentRun.find(agent_run_id)

      # The proxy URL is configured on the container; fall back to the
      # Rails app URL used by the container credential helper.
      ENV["PAID_PROXY_URL"].presence ||
        Rails.application.config.x.proxy_url.presence
    end

    # Validates and builds the health check URL upfront. Raises a
    # non-retryable error for invalid URLs so misconfiguration is
    # surfaced immediately rather than polling until timeout.
    def build_health_url(proxy_url)
      uri = URI.parse("#{proxy_url}/up")

      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise Temporalio::Error::ApplicationError.new(
          "Invalid proxy URL: #{proxy_url} (must be http or https)",
          type: "ProxyConfigurationError",
          non_retryable: true
        )
      end

      uri.to_s
    rescue URI::InvalidURIError => e
      raise Temporalio::Error::ApplicationError.new(
        "Invalid proxy URL: #{e.message}",
        type: "ProxyConfigurationError",
        non_retryable: true
      )
    end

    def healthy?(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 5
      http.read_timeout = 5
      http.use_ssl = uri.scheme == "https"

      response = http.get(uri.request_uri)
      response.code.to_i == 200
    rescue StandardError
      false
    end
  end
end
