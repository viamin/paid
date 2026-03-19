# frozen_string_literal: true

require "rails_helper"

RSpec.describe Paid::TailscaleHosts do
  describe ".enabled?" do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    it "defaults to enabled when the env var is unset" do
      allow(ENV).to receive(:[]).with("ALLOW_TAILSCALE_HOSTS").and_return(nil)

      expect(described_class.enabled?).to be(true)
    end

    it "disables access for explicit false values" do
      %w[0 false off no].each do |value|
        allow(ENV).to receive(:[]).with("ALLOW_TAILSCALE_HOSTS").and_return(value)

        expect(described_class.enabled?).to be(false), "expected #{value.inspect} to disable Tailscale hosts"
      end
    end

    it "keeps access enabled for explicit true values" do
      %w[1 true on yes].each do |value|
        allow(ENV).to receive(:[]).with("ALLOW_TAILSCALE_HOSTS").and_return(value)

        expect(described_class.enabled?).to be(true), "expected #{value.inspect} to enable Tailscale hosts"
      end
    end
  end

  describe "host allowlist entries" do
    let(:permissions) do
      ActionDispatch::HostAuthorization::Permissions.new(
        [ described_class::HOSTNAME_PATTERN, described_class::CGNAT_RANGE ]
      )
    end

    it "allows Tailscale MagicDNS hostnames" do
      expect(permissions.allows?("paid-dev.ts.net")).to be(true)
    end

    it "allows addresses inside the Tailscale CGNAT range" do
      expect(permissions.allows?("100.100.1.1")).to be(true)
    end

    it "rejects addresses outside the Tailscale CGNAT range" do
      expect(permissions.allows?("100.128.0.1")).to be(false)
    end
  end
end
