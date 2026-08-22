# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-007
RSpec.describe AgentRuns::EgressPolicy::GatewayAdapters::Kubernetes do
  subject(:adapter) { described_class.new }

  # Stand-in type so capability checks can be verified without dragging in
  # a real Kubernetes backend.
  let(:kubernetes_probe_class) { Struct.new(:kubernetes?, :namespace) }
  let(:backend) { kubernetes_probe_class.new(true, "paid") }
  let(:snapshot) do
    AgentRuns::EgressPolicy::Snapshot.new(
      mode: "proxy_restricted",
      destinations: [ { "host" => "api.partner.com", "port" => 443 } ],
      required_destinations: []
    )
  end

  it "reports capable when the backend is Kubernetes" do
    expect(adapter.capable?(backend: backend)).to be(true)
  end

  it "reports not capable when the backend lacks a Kubernetes flag" do
    expect(adapter.capable?(backend: kubernetes_probe_class.new(false, "paid"))).to be(false)
  end

  it "raises UnavailableError when ensure! is asked to set up on a non-Kubernetes backend" do
    expect {
      adapter.ensure!(agent_run: nil, snapshot: snapshot, backend: kubernetes_probe_class.new(false, "other"))
    }.to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /kubernetes/)
  end

  it "returns the in-namespace gateway service URL" do
    expect(adapter.gateway_url(snapshot: snapshot, backend: backend)).to eq("egress-gateway.paid.svc.cluster.local:3128")
  end
end
