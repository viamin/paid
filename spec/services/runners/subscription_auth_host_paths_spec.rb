# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::SubscriptionAuthHostPaths, :no_db do
  describe ".requires?" do
    it "is false for Claude managed auth (remote-safe env-token / native-file materializer)" do
      expect(described_class.requires?(runner_key: "claude", auth_mode: :managed)).to be(false)
    end

    it "is true for Claude host-forwarded subscription auth" do
      expect(described_class.requires?(runner_key: "claude", auth_mode: :host_forwarded)).to be(true)
    end

    it "is true for Codex host-forwarded subscription auth (no remote-safe materializer yet)" do
      expect(described_class.requires?(runner_key: "codex", auth_mode: :host_forwarded)).to be(true)
    end

    it "is false for Codex in api_key_proxy mode (proxy config only)" do
      expect(described_class.requires?(runner_key: "codex", auth_mode: :api_key_proxy)).to be(false)
    end

    it "is false for any runner_key in api_key_proxy mode" do
      expect(described_class.requires?(runner_key: "gemini", auth_mode: :api_key_proxy)).to be(false)
      expect(described_class.requires?(runner_key: "copilot", auth_mode: :api_key_proxy)).to be(false)
    end

    it "is true for Codex managed auth because the registered materializer requires a host mount (#2962)" do
      expect(described_class.requires?(runner_key: "codex", auth_mode: :managed)).to be(true)
    end

    it "is false for Gemini and Copilot managed auth (native-file materializer is remote-safe #2964)" do
      expect(described_class.requires?(runner_key: "gemini", auth_mode: :managed)).to be(false)
      expect(described_class.requires?(runner_key: "copilot", auth_mode: :managed)).to be(false)
    end

    it "is true for Gemini and Copilot host-forwarded subscription auth" do
      expect(described_class.requires?(runner_key: "gemini", auth_mode: :host_forwarded)).to be(true)
      expect(described_class.requires?(runner_key: "copilot", auth_mode: :host_forwarded)).to be(true)
    end

    it "treats :none auth_mode as not requiring host paths" do
      expect(described_class.requires?(runner_key: "claude", auth_mode: :none)).to be(false)
    end

    it "normalizes string runner_key and auth_mode arguments" do
      expect(described_class.requires?(runner_key: "claude", auth_mode: "host_forwarded")).to be(true)
      expect(described_class.requires?(runner_key: :claude, auth_mode: "managed")).to be(false)
    end

    it "returns true for unknown runner_keys to keep them on host-path backends" do
      expect(described_class.requires?(runner_key: "kilocode", auth_mode: :managed)).to be(true)
    end

    it "treats nil auth_mode as :none" do
      expect(described_class.requires?(runner_key: "claude", auth_mode: nil)).to be(false)
    end

    it "returns false for unrecognised auth_mode symbols" do
      expect(described_class.requires?(runner_key: "claude", auth_mode: :mystery)).to be(false)
    end
  end

  describe ".requires_for?" do
    let(:managed_source) do
      Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: "claude", auth_mode: :managed, credential_state: :active
      )
    end
    let(:host_forwarded_source) do
      Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: "codex", auth_mode: :host_forwarded
      )
    end
    let(:proxy_source) do
      Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: "codex", auth_mode: :api_key_proxy
      )
    end
    let(:none_source) do
      Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: "claude", auth_mode: :none
      )
    end

    it "delegates to .requires? using the AuthSource fields" do
      expect(described_class.requires_for?(managed_source)).to be(false)
      expect(described_class.requires_for?(host_forwarded_source)).to be(true)
      expect(described_class.requires_for?(proxy_source)).to be(false)
      expect(described_class.requires_for?(none_source)).to be(false)
    end

    it "returns false for a nil auth_source" do
      expect(described_class.requires_for?(nil)).to be(false)
    end
  end
end
