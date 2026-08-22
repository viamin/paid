# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-007
RSpec.describe AgentRuns::EgressPolicy::GatewayAdapters::ManagedMachine do
  subject(:adapter) { described_class.new }

  # Stand-in type so capability checks can be verified without dragging in
  # a real provider firewall backend.
  let(:provider_probe_class) { Struct.new(:provider) }
  let(:backend) { provider_probe_class.new("aws") }
  let(:snapshot) do
    AgentRuns::EgressPolicy::Snapshot.new(
      mode: "proxy_restricted",
      destinations: [ { "host" => "api.partner.com", "port" => 443 } ],
      required_destinations: []
    )
  end

  it "reports capable when the backend has a provider" do
    expect(adapter.capable?(backend: backend)).to be(true)
  end

  it "reports not capable when the backend has no provider" do
    expect(adapter.capable?(backend: provider_probe_class.new(nil))).to be(false)
  end

  it "raises UnavailableError when ensure! is asked to set up on a non-provider backend" do
    expect {
      adapter.ensure!(agent_run: nil, snapshot: snapshot, backend: provider_probe_class.new(nil))
    }.to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /provider/)
  end
end
