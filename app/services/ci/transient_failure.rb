# frozen_string_literal: true

module Ci
  # Detects whether CI check failures are likely transient (network errors,
  # timeouts, infrastructure flakes) rather than caused by code issues.
  # Transient failures can be retried via GitHub Actions rerun instead of
  # launching another agent run.
  class TransientFailure
    TRANSIENT_PATTERNS = [
      # Network errors
      /(?:network|dns|socket)\s*(?:error|timeout|unreachable|failure)/i,
      /ETIMEDOUT|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN/i,
      /getaddrinfo\s+(?:ENOTFOUND|EAI_AGAIN)/i,
      /connect\s+ETIMEDOUT/i,
      /Could not resolve host/i,
      /SSL_connect|OpenSSL::SSL::SSLError/i,
      /Net::OpenTimeout|Net::ReadTimeout/i,
      /SocketError|Errno::ECONNRESET|Errno::ECONNREFUSED|Errno::ETIMEDOUT/i,

      # HTTP transient errors (502, 503, 504)
      /HTTP\s+(?:502|503|504)/i,
      /Bad Gateway|Service Unavailable|Gateway Timeout/i,
      /server\s+error.*(?:502|503|504)/i,

      # Rate limiting
      /rate limit|too many requests|HTTP\s+429/i,
      /API rate limit exceeded/i,

      # Registry/download failures
      /(?:npm|yarn|bundle|pip|gem)\s+(?:ERR|error).*(?:network|fetch|ETIMEDOUT|ECONNRESET|registry)/i,
      /failed to download|download error/i,
      /Could not fetch specs from/i,
      /error fetching.*registry/i,

      # GitHub-specific transient errors
      /Resource not accessible by integration/i,
      /Git::GitExecuteError.*Could not read from remote repository/i,
      /fatal:\s+unable to access/i,
      /The requested URL returned error: 5\d\d/i,

      # Docker/container transient errors
      /(?:docker|container).*(?:timeout|unavailable|connection refused)/i,

      # General infrastructure
      /internal server error/i,
      /(?:service|server)\s+(?:temporarily\s+)?unavailable/i
    ].freeze

    # Check conclusions that are strong indicators of transient failure
    # when no code-related failure patterns are found in the output.
    TRANSIENT_CONCLUSIONS = %w[timed_out cancelled].freeze

    # Patterns that indicate a code-related (non-transient) failure
    CODE_FAILURE_PATTERNS = [
      /SyntaxError|NameError|TypeError|NoMethodError/i,
      /(?:test|spec|assertion).*(?:fail|error)/i,
      /rubocop.*offense/i,
      /eslint.*error/i,
      /compilation?\s*(?:error|failed)/i,
      /build\s*(?:error|failed)/i,
      /undefined\s+(?:method|variable|local\s+variable)/i,
      /cannot find module/i,
      /error TS\d+/i
    ].freeze

    # @param checks [Array<Hash>] Failed check run hashes (from GithubClient#check_runs_for_ref)
    # @param github_client [GithubClient] Client for fetching job logs
    # @param repo [String] Repository in "owner/name" format
    # @return [Boolean] true if all failures appear transient
    def self.call(checks:, github_client:, repo:)
      new(checks: checks, github_client: github_client, repo: repo).transient?
    end

    def initialize(checks:, github_client:, repo:)
      @checks = checks
      @github_client = github_client
      @repo = repo
    end

    def transient?
      return false if @checks.empty?

      @checks.all? { |check| transient_check?(check) }
    end

    private

    def transient_check?(check)
      output = combined_output(check)

      if output.present?
        return false if code_failure?(output)
        return true if transient_output?(output)
      end

      TRANSIENT_CONCLUSIONS.include?(check[:conclusion])
    end

    def transient_output?(text)
      TRANSIENT_PATTERNS.any? { |pattern| text.match?(pattern) }
    end

    def code_failure?(text)
      CODE_FAILURE_PATTERNS.any? { |pattern| text.match?(pattern) }
    end

    def combined_output(check)
      parts = [ check[:output_text] ]
      parts << fetch_log(check)
      parts.compact_blank.join("\n")
    end

    def fetch_log(check)
      @github_client.check_run_log(@repo, check)
    rescue GithubClient::Error
      nil
    end
  end
end
