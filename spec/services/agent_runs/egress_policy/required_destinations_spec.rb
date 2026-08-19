# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-002
RSpec.describe AgentRuns::EgressPolicy::RequiredDestinations do
  describe ".platform" do
    it "includes the egress gateway and the secrets proxy" do
      destinations = described_class.platform

      expect(destinations).to include(
        { "host" => "egress-gateway", "port" => 3128, "source" => "platform", "reason" => "egress_gateway" }
      )
      expect(destinations).to include(
        { "host" => "paid-proxy", "port" => Rails.application.config.x.paid_proxy_port,
          "source" => "platform", "reason" => "secrets_proxy" }
      )
    end

    it "accepts an explicit proxy host and port" do
      destinations = described_class.platform(proxy_host: "proxy.internal", proxy_port: 8080)

      expect(destinations).to include(
        { "host" => "proxy.internal", "port" => 8080, "source" => "platform", "reason" => "secrets_proxy" }
      )
    end
  end

  describe ".github" do
    it "includes github.com and api.github.com on 443" do
      hosts = described_class.github.map { |destination| destination["host"] }

      expect(hosts).to contain_exactly("github.com", "api.github.com")
      expect(described_class.github).to all(include("source" => "platform"))
    end
  end

  describe ".provider" do
    it "maps the claude runner to Anthropic hosts" do
      runner = build(:runner, runner_key: "claude")
      hosts = described_class.provider(runner: runner).map { |destination| destination["host"] }

      expect(hosts).to include("api.anthropic.com")
      expect(described_class.provider(runner: runner)).to all(include("source" => "runner_provider"))
    end

    it "maps agent_type claude_code to Anthropic hosts when no runner is pinned" do
      hosts = described_class.provider(runner: nil, agent_type: "claude_code").map { |destination| destination["host"] }

      expect(hosts).to include("api.anthropic.com")
    end

    it "maps codex, gemini, and copilot runners to their provider hosts" do
      expect(described_class.provider(runner: build(:runner, runner_key: "codex")).map { |d| d["host"] }).to include("chatgpt.com")
      expect(described_class.provider(runner: build(:runner, runner_key: "gemini")).map { |d| d["host"] })
        .to include("generativelanguage.googleapis.com")
      expect(described_class.provider(runner: build(:runner, runner_key: "copilot")).map { |d| d["host"] })
        .to include("api.githubcopilot.com")
    end

    it "derives the configured API provider host for direct-outbound runners" do
      runner = build(:runner, runner_key: "opencode", config: { "opencode" => { "api_provider" => "anthropic" } })
      hosts = described_class.provider(runner: runner).map { |destination| destination["host"] }

      expect(hosts).to contain_exactly("api.anthropic.com")
    end

    it "raises on a malformed registry base_url instead of silently dropping the destination" do
      runner = build(:runner, runner_key: "opencode", config: { "opencode" => { "api_provider" => "anthropic" } })
      malformed = Runner::DIRECT_OUTBOUND_API_PROVIDERS.deep_dup
      malformed["anthropic"] = malformed["anthropic"].merge(base_url: "not a url")
      stub_const("Runner::DIRECT_OUTBOUND_API_PROVIDERS", malformed)

      expect { described_class.provider(runner: runner) }
        .to raise_error(URI::InvalidURIError, /not a url/)
    end

    it "derives the configured API provider host for pi/omp runners, including google" do
      pi_runner = build(:runner, runner_key: "pi", config: { "pi" => { "api_provider" => "google" } })
      omp_runner = build(:runner, runner_key: "omp", config: { "omp" => { "api_provider" => "google" } })

      expect(described_class.provider(runner: pi_runner).map { |d| d["host"] })
        .to contain_exactly("generativelanguage.googleapis.com")
      expect(described_class.provider(runner: omp_runner).map { |d| d["host"] })
        .to contain_exactly("generativelanguage.googleapis.com")
    end

    it "maps the openrouter_free and openrouter_pareto runners to OpenRouter" do
      free = build(:runner, runner_key: "openrouter_free")
      pareto = build(:runner, runner_key: "openrouter_pareto")

      expect(described_class.provider(runner: free).map { |d| d["host"] }).to contain_exactly("openrouter.ai")
      expect(described_class.provider(runner: pareto).map { |d| d["host"] }).to contain_exactly("openrouter.ai")
    end

    it "returns an empty list for unknown runners" do
      expect(described_class.provider(runner: build(:runner, runner_key: "cursor"))).to eq([])
      expect(described_class.provider(runner: nil, agent_type: nil)).to eq([])
    end
  end

  describe "PI_OMP_PROVIDER_HOSTS" do
    it "covers every provider key Runner accepts for pi/omp" do
      expect(described_class::PI_OMP_PROVIDER_HOSTS.keys.sort).to eq(Runner::PI_API_PROVIDER_KEYS.sort)
      expect(Runner::OMP_API_PROVIDER_KEYS).to eq(Runner::PI_API_PROVIDER_KEYS)
    end
  end

  describe "runner key classification" do
    # Cursor is the only container-executable runner that never calls a
    # provider directly: it has no subscription-auth credential detection and
    # no direct-outbound mode, so its runs resolve proxy_restricted and never
    # consult provider destinations. Every other container-executable key must
    # be classified (fixed-host or config-derived) or its provider traffic
    # would silently drop out of the audit snapshot — the gap that previously
    # hid openrouter_free/openrouter_pareto provider hosts (EGRESS-POLICY-002).
    it "classifies every container-executable runner key" do
      proxy_only_runner_keys = %w[cursor]

      classified = described_class::FIXED_HOST_PROVIDER_RUNNERS.keys +
        described_class::DIRECT_OUTBOUND_PROVIDER_KEYS + proxy_only_runner_keys

      expect(classified.sort).to eq(RunnerSupport::CONTAINER_EXECUTABLE_RUNNER_KEYS.to_a.sort)
    end
  end
end
