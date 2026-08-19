# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    # Code registry of egress destinations Paid itself requires for an agent
    # run (RDR-055). Required destinations come from code, never tenant
    # settings, so tenant allowlists can only extend this set.
    #
    # Sources:
    # - platform: secrets proxy + egress gateway, required by every run
    # - github: git checkout and PR operations, required by every run
    # - runner provider: subscription-auth / direct-outbound provider APIs,
    #   required only when the run's network mode calls providers directly
    # @spec EGRESS-POLICY-002
    module RequiredDestinations
      EGRESS_GATEWAY_HOST = "egress-gateway"
      EGRESS_GATEWAY_PORT = 3128
      SECRETS_PROXY_HOST = "paid-proxy"
      HTTPS_PORT = 443

      GITHUB_HOSTS = %w[github.com api.github.com].freeze

      # Subscription-auth provider CLIs that must reach their upstream APIs
      # directly from the container.
      SUBSCRIPTION_PROVIDER_HOSTS = {
        "claude" => %w[api.anthropic.com claude.ai],
        "codex" => %w[chatgpt.com api.openai.com auth.openai.com],
        "gemini" => %w[generativelanguage.googleapis.com oauth2.googleapis.com accounts.google.com cloudcode-pa.googleapis.com],
        "copilot" => %w[api.githubcopilot.com copilot-proxy.githubusercontent.com api.github.com]
      }.freeze

      # Direct-outbound runner keys whose configured API provider supplies an
      # additional required host (base URL of the selected provider).
      DIRECT_OUTBOUND_PROVIDER_KEYS = %w[opencode kilocode pi omp].freeze

      # Pi/OMP select their upstream provider via Runner::PI_API_PROVIDERS /
      # OMP_API_PROVIDERS (a service_type + env_var map with no base_url of
      # its own -- the Pi/OMP CLIs resolve the host internally). This map is
      # deliberately keyed off that registry's keyspace rather than
      # Runner::DIRECT_OUTBOUND_API_PROVIDERS (which drives OpenCode/KiloCode
      # base-URL routing and happens to share most, but not all, keys --
      # notably it has no "google" entry). Keep these hosts in sync with
      # Runner::PI_API_PROVIDER_KEYS; a spec asserts the keyspaces match.
      PI_OMP_PROVIDER_HOSTS = {
        "anthropic" => "api.anthropic.com",
        "openai" => "api.openai.com",
        "deepseek" => "api.deepseek.com",
        "google" => "generativelanguage.googleapis.com",
        "mistral" => "api.mistral.ai",
        "minimax" => "api.minimax.io",
        "xai" => "api.x.ai",
        "zai" => "api.z.ai",
        "openrouter" => "openrouter.ai"
      }.freeze
      PI_OMP_RUNNER_KEYS = %w[pi omp].freeze

      module_function

      # Platform-required destinations for every agent run.
      # @param proxy_host [String] secrets-proxy hostname as seen from the container
      # @param proxy_port [Integer] secrets-proxy port
      # @return [Array<Hash>]
      def platform(proxy_host: SECRETS_PROXY_HOST, proxy_port: default_proxy_port)
        [
          destination(EGRESS_GATEWAY_HOST, EGRESS_GATEWAY_PORT, source: "platform", reason: "egress_gateway"),
          destination(proxy_host, proxy_port, source: "platform", reason: "secrets_proxy")
        ]
      end

      # GitHub destinations required for repo checkout and PR operations.
      # @return [Array<Hash>]
      def github
        GITHUB_HOSTS.map { |host| destination(host, HTTPS_PORT, source: "platform", reason: "github") }
      end

      # Runner/provider-required destinations. Returns [] for proxy-restricted
      # runs (provider traffic flows through the secrets proxy) and for
      # unknown runners without a configured API provider.
      # @param runner [Runner, nil] the run's runner record
      # @param agent_type [String, nil] run agent type fallback
      # @return [Array<Hash>]
      def provider(runner:, agent_type: nil)
        hosts = provider_hosts(runner: runner, agent_type: agent_type)
        hosts.map { |host| destination(host, HTTPS_PORT, source: "runner_provider", reason: "provider_api") }
      end

      def provider_hosts(runner:, agent_type: nil)
        key = runner&.runner_key
        key = Runner.runner_key_for_agent_type(agent_type) if key.blank? && agent_type.present?
        return [] if key.blank?

        SUBSCRIPTION_PROVIDER_HOSTS.fetch(key) { direct_outbound_provider_hosts(runner, key) }
      end

      def direct_outbound_provider_hosts(runner, key)
        return [] unless DIRECT_OUTBOUND_PROVIDER_KEYS.include?(key) && runner.respond_to?("#{key}_api_provider")

        provider_key = runner.public_send("#{key}_api_provider").presence
        return [] if provider_key.blank?

        host = PI_OMP_RUNNER_KEYS.include?(key) ? pi_omp_provider_host(provider_key) : base_url_host(provider_key)
        host ? [ host ] : []
      end

      # Raises when a provider key passed Runner's PI_API_PROVIDER_KEYS /
      # OMP_API_PROVIDER_KEYS validation but has no entry here -- that means
      # PI_OMP_PROVIDER_HOSTS has drifted out of sync with the Runner
      # registry, which is a code bug, not a runtime condition to swallow.
      def pi_omp_provider_host(provider_key)
        PI_OMP_PROVIDER_HOSTS.fetch(provider_key) do
          raise KeyError, "no required-destination host mapped for pi/omp provider #{provider_key.inspect}; " \
            "update AgentRuns::EgressPolicy::RequiredDestinations::PI_OMP_PROVIDER_HOSTS"
        end
      end

      def base_url_host(provider_key)
        config = Runner::DIRECT_OUTBOUND_API_PROVIDERS.fetch(provider_key, nil)
        config && URI.parse(config.fetch(:base_url)).host
      rescue URI::InvalidURIError
        nil
      end

      def default_proxy_port
        Rails.application.config.x.paid_proxy_port
      end

      def destination(host, port, source:, reason:)
        { "host" => host, "port" => port, "source" => source, "reason" => reason }
      end
    end
  end
end
