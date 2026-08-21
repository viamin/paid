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

  it "returns nil from ensure! when the operator-deployed gateway sidecar exists" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_return(instance_double(Docker::Container))

    expect(adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend)).to be_nil
  end

  it "raises Gateway::UnavailableError when the gateway sidecar is missing (fail closed)" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::NotFoundError, "not found")

    expect { adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
      .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /egress gateway container 'egress-gateway' not found/)
  end

  it "raises Gateway::UnavailableError when the gateway lookup fails for another Docker reason" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::DockerError, "daemon unreachable")

    expect { adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
      .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /egress gateway lookup failed/)
  end

  describe "#install_allowlist!" do
    let(:gateway_container) { instance_double(Docker::Container) }

    before do
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
      allow(backend).to receive(:exec_in_container)
    end

    it "writes the per-run allowlist as JSON into the gateway sidecar" do
      adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend)

      expect(backend).to have_received(:exec_in_container).with(
        gateway_container,
        array_including("sh", "-c", a_string_matching(/base64 -d/)),
        hash_including(wait: 5)
      )
    end

    it "raises Gateway::UnavailableError when the exec fails" do
      allow(backend).to receive(:exec_in_container).and_raise(Docker::Error::DockerError, "exec failed")

      expect { adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
        .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /failed to install allowlist/)
    end
  end

  describe "#collect_denials" do
    let(:gateway_container) { instance_double(Docker::Container) }

    before do
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
    end

    it "parses denial events from the sidecar log" do
      log_lines = [
        '{"host":"evil.com","port":443,"matched_rule":"no match","scheme":"https"}',
        '{"host":"bad.org","port":80,"matched_rule":"no match","scheme":"http"}'
      ].join("\n") + "\n"
      allow(backend).to receive(:exec_in_container).and_return([ [ log_lines ], [], 0 ])

      denials = adapter.collect_denials(agent_run: agent_run, backend: backend)
      expect(denials).to eq([
        { host: "evil.com", port: 443, matched_rule: "no match", scheme: "https" },
        { host: "bad.org", port: 80, matched_rule: "no match", scheme: "http" }
      ])
    end

    it "returns an empty array when the denial log does not exist" do
      allow(backend).to receive(:exec_in_container).and_return([ [ "" ], [], 0 ])

      expect(adapter.collect_denials(agent_run: agent_run, backend: backend)).to eq([])
    end

    it "returns an empty array on Docker errors" do
      allow(backend).to receive(:exec_in_container).and_raise(Docker::Error::DockerError, "container gone")

      expect(adapter.collect_denials(agent_run: agent_run, backend: backend)).to eq([])
    end
  end
end
