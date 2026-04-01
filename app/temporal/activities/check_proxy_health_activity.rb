# frozen_string_literal: true

require "uri"
require "net/http"

module Activities
  # Checks whether the Rails credential proxy is healthy and reachable.
  #
  # Called before proxy-dependent operations (clone, push) in the
  # AgentExecutionWorkflow. When the proxy is down (e.g. due to a
  # PendingMigration crash), this activity polls until it recovers,
  # effectively pausing the workflow until the proxy is available again.
  #
  # Uses the Rails health check endpoint (/up) which returns 200 when
  # the app boots without exceptions.
  class CheckProxyHealthActivity < BaseActivity
    activity_name "CheckProxyHealth"

    # Maximum time to wait for the proxy to become healthy before giving up.
    MAX_WAIT_SECONDS = 600
    # Initial interval between health check polls.
    INITIAL_POLL_INTERVAL = 5
    # Maximum interval between polls (exponential backoff cap).
    MAX_POLL_INTERVAL = 30
    # Backoff multiplier between polls.
    BACKOFF_MULTIPLIER = 2

    def execute(input)
      agent_run_id = input[:agent_run_id]
      proxy_url = proxy_base_url(agent_run_id)

      return { healthy: true } if proxy_url.blank?

      health_url = "#{proxy_url}/up"
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      interval = INITIAL_POLL_INTERVAL

      until healthy?(health_url)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed >= MAX_WAIT_SECONDS
          raise Temporalio::Error::ApplicationError.new(
            "Credential proxy unavailable after #{elapsed.round}s",
            type: "ProxyUnavailable",
            non_retryable: true
          )
        end

        logger.warn(
          message: "agent_execution.proxy_health_check_waiting",
          agent_run_id: agent_run_id,
          proxy_url: proxy_url,
          waited_seconds: elapsed.round
        )

        heartbeat("waiting_for_proxy", elapsed.round)
        sleep(interval)
        interval = [ interval * BACKOFF_MULTIPLIER, MAX_POLL_INTERVAL ].min
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      logger.info(
        message: "agent_execution.proxy_health_check_passed",
        agent_run_id: agent_run_id,
        waited_seconds: elapsed.round
      )

      { healthy: true, waited_seconds: elapsed.round }
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
