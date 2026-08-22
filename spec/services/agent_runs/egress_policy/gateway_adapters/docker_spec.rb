# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-007
RSpec.describe AgentRuns::EgressPolicy::GatewayAdapters::Docker do
  subject(:adapter) { described_class.new }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:gateway_container) do
    instance_double(Docker::Container,
      info: { "NetworkSettings" => { "Networks" => { "paid_agent" => { "Aliases" => [ "egress-gateway" ] } } } })
  end
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

  it "declares itself capable for every restricted mode when the gateway sidecar is deployed" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)

    %i[proxy_restricted approved_services proxy_only git_plus_proxy no_outbound].each do |mode|
      expect(adapter.capable?(snapshot: snapshot, backend: backend)).to be(true), "expected #{mode} to be enforceable"
    end
  end

  it "declares itself incapable when the gateway sidecar is not deployed (reject before provisioning)" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::NotFoundError, "not found")
    allow(backend).to receive(:list_containers).and_return([])

    expect(adapter.capable?(snapshot: snapshot, backend: backend)).to be(false)
  end

  it "declares itself incapable when the gateway lookup fails for another Docker reason" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::DockerError, "daemon unreachable")

    expect(adapter.capable?(snapshot: snapshot, backend: backend)).to be(false)
  end

  it "declares itself incapable without a backend to probe" do
    expect(adapter.capable?(snapshot: snapshot, backend: nil)).to be(false)
  end

  it "returns nil from ensure! when the operator-deployed gateway sidecar exists" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)

    expect(adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend)).to be_nil
  end

  it "raises Gateway::UnavailableError when the gateway sidecar is missing (fail closed)" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::NotFoundError, "not found")
    allow(backend).to receive(:list_containers).and_return([])

    expect { adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
      .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /egress gateway container 'egress-gateway' not found/)
  end

  it "raises Gateway::UnavailableError when the gateway lookup fails for another Docker reason" do
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::DockerError, "daemon unreachable")

    expect { adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
      .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /egress gateway lookup failed/)
  end

  it "resolves the gateway by network alias when no container is named after the alias" do
    aliased_container = instance_double(Docker::Container,
      info: { "NetworkSettings" => { "Networks" => { "paid_agent" => { "Aliases" => [ "egress-gateway", "abc123" ] } } } })
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::NotFoundError, "not found")
    allow(backend).to receive(:list_containers).and_return([ aliased_container ])

    expect(adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend)).to be_nil
  end

  it "raises Gateway::UnavailableError when no running container carries the gateway alias (fail closed)" do
    other_container = instance_double(Docker::Container,
      info: { "NetworkSettings" => { "Networks" => { "paid_agent" => { "Aliases" => [ "some-other-container" ] } } } })
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::NotFoundError, "not found")
    allow(backend).to receive(:list_containers).and_return([ other_container ])

    expect { adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
      .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /egress gateway container 'egress-gateway' not found/)
  end

  it "ignores alias matches published only on unrelated networks" do
    other_network_container = instance_double(Docker::Container,
      info: { "NetworkSettings" => { "Networks" => { "bridge" => { "Aliases" => [ "egress-gateway" ] } } } })
    allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::NotFoundError, "not found")
    allow(backend).to receive(:list_containers).and_return([ other_network_container ])

    expect { adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
      .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /egress gateway container 'egress-gateway' not found/)
  end

  it "falls back to a restricted-network alias when the directly resolved container is on the wrong network" do
    wrong_network_container = instance_double(Docker::Container,
      info: { "NetworkSettings" => { "Networks" => { "bridge" => { "Aliases" => [ "egress-gateway" ] } } } })
    restricted_gateway = instance_double(Docker::Container,
      info: { "NetworkSettings" => { "Networks" => { "paid_agent" => { "Aliases" => [ "egress-gateway" ] } } } })
    allow(backend).to receive(:get_container).with("egress-gateway").and_return(wrong_network_container)
    allow(backend).to receive(:list_containers).and_return([ wrong_network_container, restricted_gateway ])

    expect(adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend)).to be_nil
  end

  describe "#install_allowlist!" do
    before do
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])
    end

    it "writes the per-run allowlist as JSON into the gateway sidecar under a per-run filename" do
      adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend)

      expect(backend).to have_received(:exec_in_container).with(
        gateway_container,
        array_including("sh", "-c", a_string_matching(%r{allowlist_#{agent_run.id}\.json})),
        hash_including(wait: 5)
      )
    end

    it "keys each concurrent restricted run's allowlist by its own agent_run_id" do
      other_run = create(:agent_run, project: project)
      adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend)

      expect(backend).to have_received(:exec_in_container).with(
        gateway_container,
        array_including(a_string_matching(%r{allowlist_#{agent_run.id}\.json})),
        hash_including(wait: 5)
      )
      # The other run's path is different, so concurrent restricted runs
      # sharing the same sidecar never overwrite each other's policy.
      expect(adapter.allowlist_config_path(agent_run: agent_run))
        .not_to eq(adapter.allowlist_config_path(agent_run: other_run))
    end

    it "raises Gateway::UnavailableError when the exec fails" do
      allow(backend).to receive(:exec_in_container).and_raise(Docker::Error::DockerError, "exec failed")

      expect { adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
        .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /failed to install allowlist/)
    end

    it "raises Gateway::UnavailableError when the write command exits non-zero (fail closed)" do
      allow(backend).to receive(:exec_in_container).and_return([ [], [ "base64: invalid input\n" ], 1 ])

      expect { adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend) }
        .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /failed to install allowlist.*exit 1/)
    end

    it "resolves the gateway by network alias when the sidecar container has a different name" do
      allow(backend).to receive(:get_container).with("egress-gateway").and_raise(Docker::Error::NotFoundError, "not found")
      aliased_container = instance_double(Docker::Container,
        info: { "NetworkSettings" => { "Networks" => { "paid_agent" => { "Aliases" => [ "egress-gateway" ] } } } })
      allow(backend).to receive(:list_containers).and_return([ aliased_container ])

      adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend)

      expect(backend).to have_received(:exec_in_container).with(
        aliased_container,
        array_including("sh", "-c", a_string_matching(%r{allowlist_#{agent_run.id}\.json})),
        hash_including(wait: 5)
      )
    end
  end

  describe "#remove_allowlist!" do
    before do
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])
    end

    it "removes the per-run allowlist file from the gateway sidecar" do
      adapter.remove_allowlist!(agent_run: agent_run, backend: backend)

      expect(backend).to have_received(:exec_in_container).with(
        gateway_container,
        array_including("sh", "-c", a_string_matching(%r{rm -f .*allowlist_#{agent_run.id}\.json})),
        hash_including(wait: 5)
      )
    end

    it "swallows Docker errors so cleanup never raises on an already-removed file" do
      allow(backend).to receive(:exec_in_container).and_raise(Docker::Error::DockerError, "exec failed")

      expect { adapter.remove_allowlist!(agent_run: agent_run, backend: backend) }.not_to raise_error
    end
  end

  describe "#collect_denials" do
    before do
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
    end

    it "reads only this run's denial log (per-run path)" do
      log_lines = [
        '{"host":"evil.com","port":443,"matched_rule":"no match","scheme":"https"}',
        '{"host":"bad.org","port":80,"matched_rule":"no match","scheme":"http"}'
      ].join("\n") + "\n"
      allow(backend).to receive(:exec_in_container)
        .and_return([ [ log_lines ], [], 0 ], [ [], [], 0 ])

      adapter.collect_denials(agent_run: agent_run, backend: backend)

      expect(backend).to have_received(:exec_in_container).at_least(:once).with(
        gateway_container,
        array_including("sh", "-c", a_string_matching(%r{denials_#{agent_run.id}\.jsonl})),
        hash_including(wait: 5)
      )
    end

    it "parses denial events from the sidecar log" do
      log_lines = [
        '{"host":"evil.com","port":443,"matched_rule":"no match","scheme":"https"}',
        '{"host":"bad.org","port":80,"matched_rule":"no match","scheme":"http"}'
      ].join("\n") + "\n"
      allow(backend).to receive(:exec_in_container)
        .and_return([ [ log_lines ], [], 0 ], [ [], [], 0 ])

      denials = adapter.collect_denials(agent_run: agent_run, backend: backend)
      expect(denials).to eq([
        { host: "evil.com", port: 443, matched_rule: "no match", scheme: "https" },
        { host: "bad.org", port: 80, matched_rule: "no match", scheme: "http" }
      ])
    end

    it "truncates the per-run denial log so a re-entry does not re-ingest denials" do
      allow(backend).to receive(:exec_in_container).and_return([ [ "" ], [], 0 ], [ [], [], 0 ])

      adapter.collect_denials(agent_run: agent_run, backend: backend)

      expect(backend).to have_received(:exec_in_container).with(
        gateway_container,
        array_including("sh", "-c", a_string_matching(%r{: > /var/log/egress-gateway/denials_#{agent_run.id}\.jsonl})),
        hash_including(wait: 5)
      )
    end

    it "swallows truncation failures so a re-entry does not lose audit data" do
      call_count = 0
      allow(backend).to receive(:exec_in_container) do |_container, _command, **_opts|
        call_count += 1
        # First call: cat (the read). Second call: truncate (the write).
        if call_count == 2
          raise Docker::Error::DockerError, "truncate write failed"
        end
        [ [ "" ], [], 0 ]
      end

      expect { adapter.collect_denials(agent_run: agent_run, backend: backend) }.not_to raise_error
    end

    it "returns an empty array when the denial log does not exist" do
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 3 ])

      expect(adapter.collect_denials(agent_run: agent_run, backend: backend)).to eq([])
    end

    it "raises when reading the denial log fails for a reason other than a missing file" do
      allow(backend).to receive(:exec_in_container).and_return([ [], [ "Permission denied\n" ], 1 ])

      expect { adapter.collect_denials(agent_run: agent_run, backend: backend) }
        .to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError, /failed to read gateway denial log/)
    end

    it "does not truncate when reading the denial log fails" do
      allow(backend).to receive(:exec_in_container).and_return([ [], [ "Permission denied\n" ], 1 ])

      expect do
        adapter.collect_denials(agent_run: agent_run, backend: backend)
      end.to raise_error(AgentRuns::EgressPolicy::Gateway::UnavailableError)

      expect(backend).to have_received(:exec_in_container).once
    end
  end
end
