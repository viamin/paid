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

    it "derives the configured API provider host for pi/omp runners, including google" do
      pi_runner = build(:runner, runner_key: "pi", config: { "pi" => { "api_provider" => "google" } })
      omp_runner = build(:runner, runner_key: "omp", config: { "omp" => { "api_provider" => "google" } })

      expect(described_class.provider(runner: pi_runner).map { |d| d["host"] })
        .to contain_exactly("generativelanguage.googleapis.com")
      expect(described_class.provider(runner: omp_runner).map { |d| d["host"] })
        .to contain_exactly("generativelanguage.googleapis.com")
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
end
