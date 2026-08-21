# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-007
RSpec.describe AgentRuns::EgressPolicy::GatewayAdapters::Docker do
  subject(:adapter) { described_class.new }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:snapshot) do
    AgentRuns::EgressPolicy::Snapshot.new(
      mode: "proxy_restricted",
      destinations: [
        { "host" => "api.partner.com", "port" => 443, "source" => "project_allowlist" },
        { "host" => "*.cdn.example.com", "port" => 443, "source" => "account_allowlist" }
      ],
      required_destinations: [ { "host" => "paid-proxy", "port" => 3000 } ]
    )
  end

  it "exposes the egress-gateway Docker network alias + port" do
    expect(adapter.gateway_url(snapshot: snapshot, backend: backend)).to eq("egress-gateway:3128")
  end

  it "mirrors the snapshot destinations into the gateway allowlist" do
    expect(adapter.allowlist_for(snapshot: snapshot)).to eq([
      { host: "api.partner.com", port: 443 },
      { host: "*.cdn.example.com", port: 443 }
    ])
  end

  it "declares itself capable for every restricted mode on a Docker backend" do
    %i[proxy_restricted approved_services proxy_only git_plus_proxy no_outbound].each do |mode|
      expect(adapter.capable?(snapshot: snapshot, backend: backend)).to be(true), "expected #{mode} to be enforceable"
    end
  end

  it "returns nil from ensure! by default (operator-deployed sidecar lifecycle is not the runner's job)" do
    expect(adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend)).to be_nil
  end
end
