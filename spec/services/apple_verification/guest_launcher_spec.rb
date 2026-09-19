# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-001
RSpec.describe AppleVerification::GuestLauncher do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:provider) { instance_double(AppleVerification::GuestProvider) }

  before { FeatureFlags.enable!(:apple_verification_workers, project: project) }

  it "resolves the policy and supplies its contract before starting the guest" do
    allow(provider).to receive(:start_guest!).and_return(:guest_handle)
    snapshot = AgentRuns::EgressPolicy::Snapshot.new(mode: "proxy_restricted", destinations: [], required_destinations: [])
    allow(AgentRuns::EgressPolicy::Resolve).to receive(:resolve_and_persist!).and_return(snapshot)

    result = described_class.new(
      provider: provider,
      proxy_url: "http://paid-egress-proxy.internal:3128",
      dns_server: "paid-dns.internal"
    ).call(agent_run: agent_run)

    expect(result).to eq(:guest_handle)
    expect(provider).to have_received(:start_guest!).with(
      agent_run: agent_run,
      network_contract: hash_including("default_route" => "deny", "proxy" => hash_including("override" => "blocked"))
    )
  end

  it "does not start the guest when policy resolution is unavailable" do
    FeatureFlags.disable!(:apple_verification_workers, project: project)
    allow(provider).to receive(:start_guest!)

    expect {
      described_class.new(
        provider: provider,
        proxy_url: "http://paid-egress-proxy.internal:3128",
        dns_server: "paid-dns.internal"
      ).call(agent_run: agent_run)
    }.to raise_error(AppleVerification::GuestNetworkPolicy::UnavailableError)

    expect(provider).not_to have_received(:start_guest!)
  end
end
