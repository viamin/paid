# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-001
RSpec.describe AppleVerification::StartGuest do
  subject(:start_guest) do
    described_class.new(
      agent_run: agent_run,
      host_service: host_service,
      proxy_url: "http://paid-egress-proxy.internal:3128",
      dns_server: "paid-dns.internal"
    )
  end

  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:host_service) { instance_spy(AppleVerification::HostService) }

  it "does not call the Tart host service when the policy cannot be admitted" do
    expect { start_guest.call }.to raise_error(AppleVerification::GuestNetworkPolicy::UnavailableError)

    expect(host_service).not_to have_received(:start_guest!)
  end

  it "starts the guest through Tart with the resolved Paid network contract" do
    FeatureFlags.enable!(:apple_verification_workers, project: project)
    allow(host_service).to receive(:start_guest!).and_return("tart-guest-123")

    expect(start_guest.call).to eq("tart-guest-123")
    expect(AgentRuns::EgressPolicy::Snapshot.from_record(agent_run)).to have_attributes(mode: "proxy_restricted")
    expect(host_service).to have_received(:start_guest!).with(
      agent_run_id: agent_run.id,
      network_contract: hash_including("default_route" => "deny", "host_services" => "deny")
    )
  end
end
