# frozen_string_literal: true

module Capacity
  # Resolves the deployment-wide global concurrent execution limit.
  #
  # This is the "how many cloud machines am I willing to pay for right now"
  # control — a single ceiling on total concurrent executions across all
  # accounts, projects, and hosts. It is distinct from per-user, per-project,
  # per-host, and per-account-create-PR limits, which are all narrower scopes
  # that compose with this one.
  #
  # The limit defaults to 50, which is safe for a small single-server
  # deployment while preventing runaway provisioning on a cloud runner. It is
  # configurable via the MAX_GLOBAL_CONCURRENT_EXECUTIONS environment variable
  # and can be changed with a process restart (no redeploy of the image
  # itself when the env var is injected at runtime).
  module GlobalLimit
    DEFAULT_MAX_GLOBAL_CONCURRENT_EXECUTIONS = 50
    ENV_KEY = "MAX_GLOBAL_CONCURRENT_EXECUTIONS"

    class << self
      def max_concurrent_executions(env: ENV)
        Integer(env.fetch(ENV_KEY, DEFAULT_MAX_GLOBAL_CONCURRENT_EXECUTIONS.to_s))
      rescue ArgumentError
        DEFAULT_MAX_GLOBAL_CONCURRENT_EXECUTIONS
      end

      def enabled?(env: ENV)
        max_concurrent_executions(env: env).positive?
      end
    end
  end
end
