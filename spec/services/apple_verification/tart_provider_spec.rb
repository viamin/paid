# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-001
RSpec.describe AppleVerification::TartProvider do
  let(:agent_run) { create(:agent_run) }
  let(:host_service) { instance_spy(AppleVerification::HostService) }

  it "refuses to start a guest without a Paid network contract" do
    provider = described_class.new(host_service: host_service)

    expect {
      provider.start_guest!(agent_run: agent_run, network_contract: nil)
    }.to raise_error(AppleVerification::GuestProvider::MissingNetworkContractError)

    expect(host_service).not_to have_received(:start_guest!)
  end
end
