# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-010
# @spec CONTAINER-RUNTIME-011
# @spec CONTAINER-RUNTIME-017
# @spec CONTAINER-RUNTIME-019
# @spec CONTAINER-RUNTIME-020
# @spec CONTAINER-RUNTIME-028
# @spec EXEC-INGRESS-001
# @spec EXEC-INGRESS-002
RSpec.describe ExecutionRunners::LocalDockerRunner do
  subject(:runner) { described_class.new }

  let(:agent_run) { create(:agent_run, container_host: "local") }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:resources) { ExecutionRunners::ComputeRequirements.new(cpu_quota: 100_000, memory_bytes: 1024, disk_bytes: 2048, pids_limit: 50) }
  let(:run_spec) do
    ExecutionRunners::RunSpec.new(
      agent_run: agent_run, project: agent_run.project, image: "paid/agent:latest", command: "claude code",
      resources: resources, environment: { "FOO" => "bar" },
      networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted,
      ingress_policy: ExecutionRunners::IngressPolicy.default_deny,
      workspace: ExecutionRunners::WorkspaceStrategy.named_volume, services: [], secrets_config: nil
    )
  end
  let(:provision_service) { instance_double(Containers::Provision, container: instance_double(Docker::Container)) }
  let(:started_container) { instance_double(Docker::Container) }

  # Persists a synthetic egress policy snapshot on the +agent_run+ so
  # +AgentRuns::EgressPolicy::Snapshot.from_record+ returns it. Shared
  # between the +#provision+ tests (which consume the snapshot during
  # +apply_firewall!+) and the +.compatible?+ tests (which check whether
  # the registered adapter accepts the persisted snapshot).
  def seed_snapshot!(destinations: [], required_destinations: [], mode: "proxy_restricted", egress_profile: "locked")
    snapshot = AgentRuns::EgressPolicy::Snapshot.new(
      mode: mode,
      egress_profile: egress_profile,
      destinations: destinations,
      required_destinations: required_destinations
    )
    agent_run.update!(external_metadata: { "egress_policy" => snapshot.to_h })
    snapshot
  end

  before do
    allow(Containers).to receive(:backend_for).and_return(backend)
    allow(NetworkPolicy).to receive(:ensure_network!).and_return(instance_double(Docker::Network))
    allow(NetworkPolicy).to receive(:apply_firewall_rules)
    allow(provision_service).to receive_messages(
      firewall_service_destinations: [],
      container: started_container
    )
  end

  describe "#provision" do
    it "delegates to Containers::Provision and returns a RunnerHandle" do
      expect(Containers::Provision).to receive(:new).with(
        agent_run: agent_run, project: agent_run.project, worktree_path: nil, backend: backend,
        networking_policy: run_spec.networking_policy, egress_gateway_url: nil,
        image: "paid/agent:latest", memory_bytes: 1024, cpu_quota: 100_000, pids_limit: 50
      ).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      handle = runner.provision(spec: run_spec)

      expect(handle).to be_a(ExecutionRunners::RunnerHandle)
      expect(handle.runner_type).to eq(:local_docker)
      expect(handle.identifier).to eq("abc123")
      expect(handle.host).to eq("local")
      expect(handle.metadata).to eq(
        "agent_run_id" => agent_run.id, "worktree_path" => nil, "environment" => { "FOO" => "bar" }
      )
    end

    it "uses the agent_run's worktree_path for a bind_mount workspace strategy" do
      agent_run.update!(worktree_path: "/var/paid/worktrees/1")
      bind_mount_spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        workspace: ExecutionRunners::WorkspaceStrategy.bind_mount(reference: "/var/paid/worktrees/1")
      ))

      expect(Containers::Provision).to receive(:new)
        .with(hash_including(worktree_path: "/var/paid/worktrees/1"))
        .and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      handle = runner.provision(spec: bind_mount_spec)

      expect(handle.metadata["worktree_path"]).to eq("/var/paid/worktrees/1")
    end

    it "translates a named_volume strategy to the per-run Docker volume on workspace_ref" do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      handle = runner.provision(spec: run_spec)

      # Volume-name construction lives in the runner; the ref matches the name
      # Containers::Provision creates for a named-volume run.
      expect(handle.workspace_ref).to eq("paid-workspace-#{agent_run.id}")
    end

    it "translates a bind_mount strategy to the host path on workspace_ref" do
      bind_mount_spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        workspace: ExecutionRunners::WorkspaceStrategy.bind_mount(reference: "/var/paid/worktrees/1")
      ))
      allow(Containers::Provision).to receive(:new)
        .with(hash_including(worktree_path: "/var/paid/worktrees/1"))
        .and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      handle = runner.provision(spec: bind_mount_spec)

      expect(handle.workspace_ref).to eq("/var/paid/worktrees/1")
      expect(handle.workspace_ref).not_to include("paid-workspace-")
    end

    it "carries the workspace reference through a full provision → start → cleanup round-trip" do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      handle = runner.provision(spec: run_spec)

      # The runner owns workspace_ref; it never leaks a Docker volume name into
      # the caller, and the handle carries it for recovery/cleanup.
      expect(handle.workspace_ref).to eq("paid-workspace-#{agent_run.id}")
      reloaded = ExecutionRunners::RunnerHandle.from_json(handle.to_json)
      expect(reloaded.workspace_ref).to eq(handle.workspace_ref)

      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: nil)
        .and_return(provision_service)
      allow(provision_service).to receive_messages(
        execute: Containers::Provision::Result.success(stdout: "ok\n", stderr: "", exit_code: 0),
        cleanup: nil
      )

      result = runner.start(handle: reloaded, command: "echo ok", timeout: 60, startup_timeout: 30,
        idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil)
      expect(result).to be_success

      expect { runner.cleanup(handle: reloaded, force: true) }.not_to raise_error
    end

    it "wraps a Containers::Provision::ProvisionError in ExecutionRunners::ProvisionError" do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_raise(
        Containers::Provision::ProvisionError, "Docker error: no space left"
      )

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, "Docker error: no space left")
    end

    it "fails closed when the run spec omits an ingress policy" do
      spec_without_ingress = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(ingress_policy: nil))

      expect { runner.provision(spec: spec_without_ingress) }
        .to raise_error(ExecutionRunners::ProvisionError, "RunSpec requires an IngressPolicy")
    end

    it "ensures the network from the NetworkingPolicy before delegating to Containers::Provision" do
      expect(NetworkPolicy).to receive(:ensure_network!)
        .with(network: NetworkPolicy::NETWORK_NAME, backend: backend)
        .ordered
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      runner.provision(spec: run_spec)
    end

    it "applies firewall rules via NetworkPolicy when the policy requires it" do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container,
              github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
              proxy_host: nil,
              service_destinations: [],
              backend: backend)

      runner.provision(spec: run_spec)
    end

    it "normalizes policy allow_destinations from {host:, port:} to {ip:, port:} for the firewall" do
      allow_destinations_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted(
            allow_destinations: [ { host: "10.0.0.1", port: 5432 } ]
          )
        )
      )
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container,
              github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
              proxy_host: nil,
              service_destinations: [ { ip: "10.0.0.1", port: 5432 } ],
              backend: backend)

      runner.provision(spec: allow_destinations_spec)
    end

    it "merges firewall destinations from Provision (service IPs + preview tunnel) into the rules" do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        firewall_service_destinations: [ { ip: "192.0.2.10", port: 443 } ]
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container,
              github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
              proxy_host: nil,
              service_destinations: [ { ip: "192.0.2.10", port: 443 } ],
              backend: backend)

      runner.provision(spec: run_spec)
    end

    it "translates the :no_outbound intent to a firewall that omits the proxy and GitHub allow rules" do
      no_outbound_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.no_outbound
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::NETWORK_NAME))
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container, github_ips: [], proxy_host: false,
              service_destinations: [], backend: backend)

      runner.provision(spec: no_outbound_spec)
    end

    it "translates the :proxy_only intent to a firewall that allows the proxy but not GitHub" do
      proxy_only_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.proxy_only
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::NETWORK_NAME))
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container, github_ips: [], proxy_host: nil,
              service_destinations: [], backend: backend)

      runner.provision(spec: proxy_only_spec)
    end

    it "translates the :git_plus_proxy intent to a firewall that allows the proxy and GitHub but not services" do
      git_proxy_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.git_plus_proxy
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::NETWORK_NAME))
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container, github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
              proxy_host: nil, service_destinations: [], backend: backend)

      runner.provision(spec: git_proxy_spec)
    end

    it "excludes service container IPs from the firewall for :no_outbound even when services are provisioned" do
      no_outbound_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.no_outbound
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::NETWORK_NAME))
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        firewall_service_destinations: [ { ip: "192.0.2.10", port: 5432 } ]
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container, github_ips: [], proxy_host: false,
              service_destinations: [], backend: backend)

      runner.provision(spec: no_outbound_spec)
    end

    it "excludes service container IPs from the firewall for :git_plus_proxy even when services are provisioned" do
      git_proxy_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.git_plus_proxy
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::NETWORK_NAME))
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        firewall_service_destinations: [ { ip: "192.0.2.10", port: 5432 } ]
      )

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container, github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
              proxy_host: nil, service_destinations: [], backend: backend)

      runner.provision(spec: git_proxy_spec)
    end

    it "skips NetworkPolicy firewall application when the policy is unrestricted" do
      direct_outbound_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.direct_outbound
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::INFRA_NETWORK_NAME))
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

      runner.provision(spec: direct_outbound_spec)
    end

    it "skips NetworkPolicy firewall application when the policy is :explicit_internet" do
      explicit_internet_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.explicit_internet
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::INFRA_NETWORK_NAME))
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

      runner.provision(spec: explicit_internet_spec)
    end

    it "threads the locked egress profile through to Containers::Provision without inspecting it" do
      expect(Containers::Provision).to receive(:new)
        .with(hash_including(networking_policy: run_spec.networking_policy))
        .and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect { runner.provision(spec: run_spec) }.not_to raise_error
    end

    it "threads the research egress profile through the portable contract" do
      research_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted(
            allow_destinations: [ { host: "research-gateway", port: 8443 } ],
            egress_profile: :research
          )
        )
      )
      expect(Containers::Provision).to receive(:new)
        .with(hash_including(networking_policy: research_spec.networking_policy))
        .and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      runner.provision(spec: research_spec)

      expect(research_spec.networking_policy).to be_research
      expect(research_spec.networking_policy.allow_destinations).to eq([ { host: "research-gateway", port: 8443 } ])
    end

    it "threads the open / break-glass egress profile through the portable contract" do
      open_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.direct_outbound(egress_profile: :open)
        )
      )
      allow(NetworkPolicy).to receive(:contract_for_policy)
        .and_return(double(network: NetworkPolicy::INFRA_NETWORK_NAME))
      expect(Containers::Provision).to receive(:new)
        .with(hash_including(networking_policy: open_spec.networking_policy))
        .and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      runner.provision(spec: open_spec)

      expect(open_spec.networking_policy).to be_open
      expect(open_spec.networking_policy).not_to be_firewall
    end

    it "raises ProvisionError when network setup fails" do
      allow(NetworkPolicy).to receive(:ensure_network!)
        .and_raise(NetworkPolicy::Error, "Failed to create agent network")

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /Network setup failed/)
    end

    it "rejects unsupported inbound exposure before provisioning" do
      debug_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          ingress_policy: ExecutionRunners::IngressPolicy.default_deny(
            capabilities: [
              ExecutionRunners::IngressCapability.build(
                kind: "debug",
                scope: "public_listener",
                expires_at: 2.days.from_now.iso8601,
                authentication: { required: true, type: "signed_token" },
                granted_at: 1.day.ago.iso8601,
                granted_by: "user:42"
              )
            ]
          )
        )
      )

      expect(Containers::Provision).not_to receive(:new)

      expect { runner.provision(spec: debug_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, "Unsupported inbound exposure requested: debug.")
    end

    it "rejects an unsupported networking policy before any Docker side effects" do
      unsupported_policy = Struct.new(:mode).new(:unknown_mode)
      unsupported_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: unsupported_policy
        )
      )

      expect(NetworkPolicy).not_to receive(:ensure_network!)
      expect(Containers::Provision).not_to receive(:new)

      expect { runner.provision(spec: unsupported_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /does not support networking policy :unknown_mode/)
    end

    it "rejects a missing networking policy before any Docker side effects" do
      missing_policy_spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(networking_policy: nil))

      expect(NetworkPolicy).not_to receive(:ensure_network!)
      expect(Containers::Provision).not_to receive(:new)

      expect { runner.provision(spec: missing_policy_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /RunSpec requires a NetworkingPolicy/)
    end

    it "cleans up the provisioned container when firewall application fails in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      seed_snapshot!
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(instance_double(Docker::Container))
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        agent_run: agent_run
      )
      allow(NetworkPolicy).to receive(:apply_firewall_rules)
        .and_raise(NetworkPolicy::Error, "iptables not available")

      expect(provision_service).to receive(:cleanup)

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /Firewall setup failed/)
    end

    # @spec EGRESS-POLICY-007
    it "threads the gateway URL into the firewall destinations as {ip:, port:}" do
      seed_snapshot!(destinations: [ { "host" => "api.partner.com", "port" => 443, "source" => "project_allowlist" } ])
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(instance_double(Docker::Container))
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])
      stub_provision_success!

      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container,
              github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
              proxy_host: nil,
              service_destinations: [ { ip: "egress-gateway", port: 3128 } ],
              backend: backend)

      runner.provision(spec: run_spec)
    end

    # @spec EGRESS-POLICY-007
    it "routes tenant-allowlisted destinations through the gateway rather than opening them directly in iptables" do
      seed_snapshot!(destinations: [
        { "host" => "api.partner.com", "port" => 443, "source" => "project_allowlist" },
        { "host" => "metrics.example.com", "port" => 8443, "source" => "account_allowlist" }
      ])
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(instance_double(Docker::Container))
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])
      stub_provision_success!

      expect(NetworkPolicy).to receive(:apply_firewall_rules) do |_container, **kwargs|
        # Snapshot destinations must NOT appear as direct iptables rules:
        # they are enforced by the gateway's own allowlist, so denials go
        # through the gateway audit trail and bypass is impossible.
        expect(kwargs[:service_destinations]).not_to include(
          a_hash_including(ip: "api.partner.com"),
          a_hash_including(ip: "metrics.example.com")
        )
        expect(kwargs[:service_destinations]).to include({ ip: "egress-gateway", port: 3128 })
      end

      runner.provision(spec: run_spec)
    end

    def stub_provision_success!
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )
    end

    # @spec EGRESS-POLICY-007
    it "calls the gateway adapter's ensure! before provisioning the container" do
      seed_snapshot!
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        gateway_url: "egress-gateway:3128",
        allowlist_for: [],
        ensure!: nil,
        install_allowlist!: nil
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      stub_provision_success!

      runner.provision(spec: run_spec)

      expect(adapter).to have_received(:ensure!).with(
        hash_including(agent_run: agent_run, backend: backend)
      )
      expect(NetworkPolicy).to have_received(:apply_firewall_rules).with(
        started_container,
        hash_including(service_destinations: [ { ip: "egress-gateway", port: 3128 } ])
      )
    end

    # @spec EGRESS-POLICY-007
    it "skips gateway destinations for unrestricted runs that carry no snapshot" do
      stub_provision_success!

      expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

      runner.provision(spec: ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.direct_outbound
      )))
    end

    # @spec EGRESS-POLICY-007
    it "fails closed in production when the gateway adapter cannot be brought up" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      seed_snapshot!
      stub_failing_gateway!

      expect(Containers::Provision).not_to receive(:new)

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /Egress gateway setup failed/)
    end

    # @spec EGRESS-POLICY-007
    it "logs but does not raise when the gateway adapter fails in non-production environments" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      seed_snapshot!
      stub_failing_gateway!
      stub_provision_success!

      expect(Rails.logger).to receive(:warn).with(hash_including(message: "container.egress_gateway.failed"))
      expect { runner.provision(spec: run_spec) }.not_to raise_error
    end

    def stub_failing_gateway!
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        gateway_url: "egress-gateway:3128",
        allowlist_for: []
      )
      allow(adapter).to receive(:ensure!).and_raise(
        AgentRuns::EgressPolicy::Gateway::UnavailableError, "gateway sidecar not present"
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
    end

    # @spec EGRESS-POLICY-007
    it "fails closed in production when a restricted run has no persisted egress snapshot" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

      expect(Containers::Provision).not_to receive(:new)
      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "container.egress_gateway.missing_snapshot", agent_run_id: agent_run.id)
      )

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /no egress policy snapshot persisted/)
    end

    # @spec EGRESS-POLICY-007
    it "logs but does not raise when a restricted run has no persisted egress snapshot outside production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      stub_provision_success!

      expect(NetworkPolicy).to receive(:apply_firewall_rules).with(
        started_container, hash_including(service_destinations: [])
      )
      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "container.egress_gateway.missing_snapshot", agent_run_id: agent_run.id)
      )

      expect { runner.provision(spec: run_spec) }.not_to raise_error
    end
  end

  describe "#start" do
    let(:handle) do
      ExecutionRunners::RunnerHandle.new(
        runner_type: :local_docker, identifier: "abc123", host: "local", workspace_ref: "paid-workspace-1",
        metadata: { "agent_run_id" => agent_run.id, "worktree_path" => nil, "environment" => { "FOO" => "bar" } }
      )
    end

    before do
      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: nil)
        .and_return(provision_service)
    end

    it "delegates to Containers::Provision#execute and returns a successful ExecutionResult" do
      allow(provision_service).to receive(:execute).with(
        "echo ok", timeout: 60, startup_timeout: 30, idle_timeout: 30, env: { "FOO" => "bar" },
        preparation: nil, heartbeat_path: nil, abort_patterns: nil
      ).and_return(Containers::Provision::Result.success(stdout: "ok\n", stderr: "", exit_code: 0))

      result = runner.start(handle: handle, command: "echo ok", timeout: 60, startup_timeout: 30,
        idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil)

      expect(result).to be_a(ExecutionRunners::ExecutionResult)
      expect(result).to be_success
      expect(result.stdout).to eq("ok\n")
      expect(result.exit_code).to eq(0)
    end

    it "captures OOM and timeout classification on failure" do
      allow(provision_service).to receive(:execute).and_return(
        Containers::Provision::Result.failure(
          error: "Command exited with code 137", stdout: "", stderr: "", exit_code: 137,
          oom_killed: true, memory_limit_bytes: 4_294_967_296, container_running: false
        )
      )

      result = runner.start(handle: handle, command: "echo ok", timeout: 60, startup_timeout: 30,
        idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil)

      expect(result).to be_failure
      expect(result.oom_killed).to be(true)
      expect(result.memory_limit_bytes).to eq(4_294_967_296)
      expect(result.environment_running).to be(false)
    end

    it "translates Containers::Provision::StartupTimeoutError into ExecutionRunners::StartupTimeoutError" do
      allow(provision_service).to receive(:execute).and_raise(
        Containers::Provision::StartupTimeoutError.new("No output received", diagnostics: { elapsed: 30 })
      )

      expect { runner.start(handle: handle, command: "echo ok", timeout: 60, startup_timeout: 30,
        idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil) }
        .to raise_error(ExecutionRunners::StartupTimeoutError) { |e| expect(e.diagnostics).to eq(elapsed: 30) }
    end

    it "translates Containers::Provision::OutputAbortError into ExecutionRunners::OutputAbortError" do
      allow(provision_service).to receive(:execute).and_raise(
        Containers::Provision::OutputAbortError.new("aborted", matched_output: "quota exceeded", source: :pattern)
      )

      expect { runner.start(handle: handle, command: "echo ok", timeout: 60, startup_timeout: 30,
        idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil) }
        .to raise_error(ExecutionRunners::OutputAbortError) { |e| expect(e.matched_output).to eq("quota exceeded") }
    end

    it "raises ProvisionError when the agent run record is missing" do
      allow(AgentRun).to receive(:find).and_raise(ActiveRecord::RecordNotFound)

      expect { runner.start(handle: handle, command: "echo ok", timeout: 60, startup_timeout: 30,
        idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil) }
        .to raise_error(ExecutionRunners::ProvisionError)
    end
  end

  describe "#running?" do
    let(:handle) do
      ExecutionRunners::RunnerHandle.new(runner_type: :local_docker, identifier: "abc123", host: "local",
        workspace_ref: "paid-workspace-1", metadata: { "agent_run_id" => agent_run.id })
    end

    it "delegates to Containers::Provision#container_running?" do
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:container_running?).and_return(true)

      expect(runner.running?(handle: handle)).to be(true)
    end

    it "returns false when the container can no longer be reconnected to" do
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "Container abc123 not found")

      expect(runner.running?(handle: handle)).to be(false)
    end

    it "returns false when the agent run record is missing" do
      allow(AgentRun).to receive(:find).and_raise(ActiveRecord::RecordNotFound)

      expect(runner.running?(handle: handle)).to be(false)
    end
  end

  describe "#status" do
    let(:handle) do
      ExecutionRunners::RunnerHandle.new(runner_type: :local_docker, identifier: "abc123", host: "local",
        workspace_ref: "paid-workspace-1", metadata: { "agent_run_id" => agent_run.id })
    end

    before do
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
    end

    it "returns a running status when the container is running" do
      allow(provision_service).to receive(:container_status)
        .and_return(running: true, exit_code: nil, oom_killed: false, memory_limit_bytes: 1024)

      status = runner.status(handle: handle)

      expect(status).to be_a(ExecutionRunners::ExecutionStatus)
      expect(status).to be_running
      expect(status.exit_code).to be_nil
      expect(status.memory_limit).to eq(1024)
    end

    it "returns an exited status with the exit code" do
      allow(provision_service).to receive(:container_status)
        .and_return(running: false, exit_code: 1, oom_killed: false, memory_limit_bytes: 1024)

      status = runner.status(handle: handle)

      expect(status).to be_exited
      expect(status.exit_code).to eq(1)
      expect(status).not_to be_oom_killed
    end

    it "reports oom_killed when the container was OOM killed" do
      allow(provision_service).to receive(:container_status)
        .and_return(running: false, exit_code: 137, oom_killed: true, memory_limit_bytes: 4_294_967_296)

      status = runner.status(handle: handle)

      expect(status).to be_oom_killed
      expect(status.oom_killed).to be(true)
      expect(status.exit_code).to eq(137)
    end

    it "returns not_found when the container can no longer be reconnected to" do
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "Container abc123 not found")

      status = runner.status(handle: handle)

      expect(status).to be_not_found
      expect(status.exit_code).to be_nil
    end

    it "returns not_found when inspection returns no state" do
      allow(provision_service).to receive(:container_status).and_return({})

      expect(runner.status(handle: handle)).to be_not_found
    end

    it "returns not_found when the agent run record is missing" do
      allow(AgentRun).to receive(:find).and_raise(ActiveRecord::RecordNotFound)

      expect(runner.status(handle: handle)).to be_not_found
    end
  end

  describe "#reconnect" do
    let(:handle) do
      ExecutionRunners::RunnerHandle.new(runner_type: :local_docker, identifier: "abc123", host: "local",
        workspace_ref: "paid-workspace-1",
        metadata: { "agent_run_id" => agent_run.id, "worktree_path" => nil })
    end

    it "translates the handle identifier to a Docker container ID and reconnects" do
      expect(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: nil)
        .and_return(provision_service)

      expect(runner.reconnect(handle: handle)).to eq(provision_service)
    end

    it "raises ProvisionError when the container is missing" do
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "Container abc123 not found")

      expect { runner.reconnect(handle: handle) }
        .to raise_error(Containers::Provision::ProvisionError, /not found/)
    end

    it "threads worktree_path from the handle metadata" do
      agent_run.update!(worktree_path: "/var/paid/worktrees/1")
      path_handle = handle.with(metadata: handle.metadata.merge("worktree_path" => "/var/paid/worktrees/1"))

      expect(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: "/var/paid/worktrees/1")
        .and_return(provision_service)

      runner.reconnect(handle: path_handle)
    end
  end

  describe "#cancel" do
    let(:handle) do
      ExecutionRunners::RunnerHandle.new(runner_type: :local_docker, identifier: "abc123", host: "local",
        workspace_ref: "paid-workspace-1", metadata: { "agent_run_id" => agent_run.id })
    end

    it "stops the container via the backend when it is running" do
      container = instance_double(Docker::Container)
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive_messages(container_running?: true, container: container, backend: backend)
      expect(backend).to receive(:stop_container).with(container, timeout: 10)

      runner.cancel(handle: handle)
    end

    it "does nothing when the container is not running" do
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:container_running?).and_return(false)
      expect(backend).not_to receive(:stop_container)

      runner.cancel(handle: handle)
    end

    it "does not raise when the container is already gone" do
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "Container abc123 not found")

      expect { runner.cancel(handle: handle) }.not_to raise_error
    end

    it "does not raise when the agent run record is missing" do
      allow(AgentRun).to receive(:find).and_raise(ActiveRecord::RecordNotFound)

      expect { runner.cancel(handle: handle) }.not_to raise_error
    end
  end

  describe "#cleanup" do
    let(:handle) do
      ExecutionRunners::RunnerHandle.new(runner_type: :local_docker, identifier: "abc123", host: "local",
        workspace_ref: "paid-workspace-1", metadata: { "agent_run_id" => agent_run.id })
    end

    it "delegates to Containers::Provision#cleanup" do
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      expect(provision_service).to receive(:cleanup).with(force: true)

      runner.cleanup(handle: handle, force: true)
    end

    it "is idempotent when the container was already torn down" do
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "Container abc123 not found")

      expect { runner.cleanup(handle: handle, force: false) }.not_to raise_error
    end

    it "does not raise when the agent run record is missing" do
      allow(AgentRun).to receive(:find).and_raise(ActiveRecord::RecordNotFound)

      expect { runner.cleanup(handle: handle, force: false) }.not_to raise_error
    end

    # @spec EGRESS-POLICY-007
    it "drains gateway denials to EgressSecurityEvent rows for restricted runs" do
      seed_snapshot!(destinations: [ { "host" => "evil.example.com", "port" => 443, "source" => "project_allowlist" } ])
      adapter = stub_gateway_collect_denials!(
        host: "evil.example.com", port: 443, matched_rule: "no matching rule", scheme: "https"
      )
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      allow(Containers).to receive(:backend_for).with("local").and_return(backend)

      expect { runner.cleanup(handle: handle, force: true) }.to change(EgressSecurityEvent, :count).by(1)

      expect(EgressSecurityEvent.last).to have_attributes(
        event_kind: "denied_egress",
        destination_host: "evil.example.com",
        destination_port: 443,
        source_layer: "gateway",
        agent_run: agent_run
      )
      expect(adapter).to have_received(:collect_denials).with(agent_run: agent_run, backend: backend)
    end

    # @spec EGRESS-POLICY-007
    it "skips the gateway drain for runs with no persisted snapshot" do
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker)
      expect(adapter).not_to receive(:collect_denials)
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)

      expect { runner.cleanup(handle: handle, force: true) }.not_to change(EgressSecurityEvent, :count)
    end

    # @spec EGRESS-POLICY-007
    it "skips the gateway drain for unrestricted runs that persisted a snapshot" do
      seed_snapshot!(mode: "direct_outbound", destinations: [])
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker)
      expect(adapter).not_to receive(:collect_denials)
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)

      expect { runner.cleanup(handle: handle, force: true) }.not_to change(EgressSecurityEvent, :count)
    end

    # @spec EGRESS-POLICY-007
    it "logs a warning but never raises when the gateway drain itself fails" do
      seed_snapshot!(destinations: [ { "host" => "evil.example.com", "port" => 443, "source" => "project_allowlist" } ])
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker)
      allow(adapter).to receive(:collect_denials).and_raise(StandardError, "sidecar exec failed")
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      allow(Containers).to receive(:backend_for).with("local").and_return(backend)

      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "container.gateway.denial_drain_failed", agent_run_id: agent_run.id)
      )

      expect { runner.cleanup(handle: handle, force: true) }.not_to raise_error
    end

    # @spec EGRESS-POLICY-007
    it "skips the gateway drain when the handle omits an agent_run_id" do
      no_id_handle = ExecutionRunners::RunnerHandle.new(
        runner_type: :local_docker, identifier: "abc123", host: "local",
        workspace_ref: "paid-workspace-1", metadata: {}
      )
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker)
      expect(adapter).not_to receive(:collect_denials)
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)

      expect { runner.cleanup(handle: no_id_handle, force: true) }.not_to raise_error
    end

    # Builds an instance double for the gateway adapter whose
    # +#collect_denials+ returns a single denial record built from the
    # given kwargs. Returns the double so specs can assert against it.
    def stub_gateway_collect_denials!(host:, port:, matched_rule:, scheme:)
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        collect_denials: [ { host: host, port: port, matched_rule: matched_rule, scheme: scheme } ]
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      adapter
    end
  end

  describe ".workspace_volume_name_for" do
    it "constructs the per-run Docker named-volume name" do
      expect(described_class.workspace_volume_name_for(42)).to eq("paid-workspace-42")
    end
  end

  describe "#cleanup_workspace_reference" do
    let(:volume) { instance_double(Docker::Volume) }

    it "deletes the named workspace volume via the owning backend" do
      allow(Containers).to receive(:backend_for).with("remote").and_return(backend)
      allow(backend).to receive(:get_volume).with("paid-workspace-#{agent_run.id}", host: "remote").and_return(volume)
      allow(backend).to receive(:delete_volume).with(volume)

      runner.cleanup_workspace_reference(agent_run: agent_run, host: "remote")

      expect(backend).to have_received(:get_volume).with("paid-workspace-#{agent_run.id}", host: "remote")
      expect(backend).to have_received(:delete_volume).with(volume)
    end

    it "is a no-op when the volume was already removed" do
      allow(Containers).to receive(:backend_for).and_return(backend)
      allow(backend).to receive(:get_volume).and_raise(Docker::Error::NotFoundError)

      expect { runner.cleanup_workspace_reference(agent_run: agent_run, host: "remote") }.not_to raise_error
    end

    it "logs a warning instead of raising on other Docker errors" do
      allow(Containers).to receive(:backend_for).and_return(backend)
      allow(backend).to receive(:get_volume).and_raise(Docker::Error::DockerError, "daemon down")

      expect(Rails.logger).to receive(:warn).with(hash_including(message: "container_manager.orphaned_volume_cleanup_failed"))
      expect { runner.cleanup_workspace_reference(agent_run: agent_run, host: "remote") }.not_to raise_error
    end
  end

  describe ".compatible?" do
    it "delegates to Containers::Provision.compatibility_for" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .with(agent_run: agent_run, backend: backend, worktree_path: nil)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))

      result = described_class.compatible?(spec: run_spec, backend: backend)

      expect(result).to be_a(ExecutionRunners::CompatibilityResult)
      expect(result.compatible).to be(true)
    end

    it "supports every RDR-062 networking intent (Docker implements every shape)" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))

      %i[no_outbound proxy_only git_plus_proxy approved_services
         model_direct explicit_internet subscription_auth direct_outbound].each do |mode|
        policy = ExecutionRunners::NetworkingPolicy.public_send(mode)
        spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(networking_policy: policy))

        result = described_class.compatible?(spec: spec, backend: backend)

        expect(result.compatible).to be(true), "expected #{mode} policy to be compatible, got #{result.error_message}"
      end
    end

    it "rejects a spec with no networking policy before provisioning" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(networking_policy: nil))

      result = described_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("networking policy nil")
    end

    # @spec EGRESS-POLICY-007
    it "rejects a restricted spec when the runtime cannot enforce it (no gateway adapter)" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      allow(described_class).to receive(:gateway_adapter).and_return(nil)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
      ))

      result = described_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("cannot enforce the egress policy snapshot")
    end

    # @spec EGRESS-POLICY-007
    it "accepts a restricted spec when a gateway adapter is registered" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
      ))

      result = described_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true), result.error_message
    end

    # @spec EGRESS-POLICY-007
    it "accepts an unrestricted spec even without a gateway adapter (open profiles don't enforce domains)" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      allow(described_class).to receive(:gateway_adapter).and_return(nil)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.direct_outbound
      ))

      result = described_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true)
    end

    # @spec EGRESS-POLICY-007
    it "rejects a restricted spec when the registered adapter is not capable on this backend" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Kubernetes,
        capable?: false
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
      ))

      result = described_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("cannot enforce the egress policy snapshot")
      expect(adapter).to have_received(:capable?).with(hash_including(backend: backend))
    end

    # @spec EGRESS-POLICY-007
    it "asks the adapter about capability with the persisted snapshot when one exists" do
      seed_snapshot!(destinations: [ { "host" => "api.partner.com", "port" => 443, "source" => "project_allowlist" } ])
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Kubernetes,
        capable?: true
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
      ))

      result = described_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true), result.error_message
      expect(adapter).to have_received(:capable?) do |kwargs|
        expect(kwargs[:backend]).to eq(backend)
        expect(kwargs[:snapshot]).to be_a(AgentRuns::EgressPolicy::Snapshot)
        expect(kwargs[:snapshot].destinations.first["host"]).to eq("api.partner.com")
      end
    end
  end

  describe ".gateway_adapter" do
    # @spec EGRESS-POLICY-007
    it "returns the Docker gateway adapter by default" do
      expect(described_class.gateway_adapter).to be_a(AgentRuns::EgressPolicy::GatewayAdapters::Docker)
    end

    # @spec EGRESS-POLICY-007
    it "honors a narrowed gateway adapter override (test double)" do
      custom = Object.new
      allow(described_class).to receive(:gateway_adapter).and_return(custom)
      expect(described_class.gateway_adapter).to eq(custom)
    end
  end

  describe ".supports_policy?" do
    it "returns true for every RDR-062 networking intent" do
      %i[no_outbound proxy_only git_plus_proxy approved_services
         model_direct explicit_internet subscription_auth direct_outbound].each do |mode|
        policy = ExecutionRunners::NetworkingPolicy.public_send(mode)

        expect(described_class.supports_policy?(policy)).to be(true), "expected #{mode} policy to be supported"
      end
    end

    it "returns false when the policy is nil" do
      expect(described_class.supports_policy?(nil)).to be(false)
    end

    it "returns false for an unknown policy mode" do
      policy = Struct.new(:mode).new(:unknown_mode)

      expect(described_class.supports_policy?(policy)).to be(false)
    end
  end

  describe ".ping" do
    it "delegates to Containers::HealthCheck" do
      allow(Containers).to receive(:backend).and_return(backend)
      allow(Containers::HealthCheck).to receive(:ping).with(backend).and_return(
        Containers::HealthCheck::Result.new(backend_identifier: "local", healthy: true, pinged_at: Time.current, error_message: nil)
      )

      expect(described_class.ping).to be(true)
    end
  end

  describe "RunnerHandle round-trip" do
    it "provisions, serializes, deserializes, starts, and cleans up through the same handle" do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      handle = runner.provision(spec: run_spec)
      reloaded_handle = ExecutionRunners::RunnerHandle.from_json(handle.to_json)

      expect(reloaded_handle).to eq(handle)

      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: nil)
        .and_return(provision_service)
      allow(provision_service).to receive_messages(provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"), execute: Containers::Provision::Result.success(stdout: "ok\n", stderr: "", exit_code: 0))
      allow(provision_service).to receive(:cleanup)

      result = runner.start(handle: reloaded_handle, command: "echo ok", timeout: 60, startup_timeout: 30,
        idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil)
      expect(result).to be_success

      expect { runner.cleanup(handle: reloaded_handle, force: true) }.not_to raise_error
    end
  end

  it_behaves_like "an ExecutionRunner implementation" do
    let(:valid_handle) do
      ExecutionRunners::RunnerHandle.new(runner_type: :local_docker, identifier: "abc123", host: "local",
        workspace_ref: "paid-workspace-1", metadata: { "agent_run_id" => agent_run.id, "environment" => {} })
    end

    before do
      allow(Containers::Provision).to receive_messages(new: provision_service, reconnect: provision_service, compatibility_for: Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      allow(Containers).to receive(:backend).and_return(backend)
      allow(Containers::HealthCheck).to receive(:ping)
        .and_return(Containers::HealthCheck::Result.new(backend_identifier: "local", healthy: true, pinged_at: Time.current, error_message: nil))
      allow(backend).to receive(:stop_container)
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        execute: Containers::Provision::Result.success(stdout: "ok\n", stderr: "", exit_code: 0),
        container_running?: true, container: instance_double(Docker::Container), backend: backend, cleanup: nil
      )
      allow(provision_service).to receive_messages(firewall_service_destinations: [])
    end
  end

  # RDR-057 baseline: the Docker runner passes the provider-neutral
  # no-shared-filesystem conformance suite with its platform stubbed. The
  # stubs constrain Containers::Provision to worktree_path: nil — the
  # in-container clone path — so a regression that reintroduces a host
  # worktree for normal create-PR execution fails here.
  # @spec CONTAINER-RUNTIME-019
  it_behaves_like "a no-shared-filesystem runner" do
    let(:conformance_run) do
      create(
        :agent_run,
        goal: "create_pr",
        branch_name: "feature/conformance",
        base_commit_sha: "cafebabecafebabecafebabecafebabecafebabe",
        result_commit_sha: "f00dcafef00dcafef00dcafef00dcafef00dcafe",
        container_host: "local",
        verification_result: {
          "status" => "passed",
          "artifacts" => [ { "kind" => "trace", "url" => "https://artifacts.test/conformance.zip" } ]
        }
      )
    end

    before do
      allow(Containers::Provision).to receive(:new)
        .with(hash_including(worktree_path: nil))
        .and_return(provision_service)
      allow(Containers::Provision).to receive(:reconnect)
        .with(hash_including(worktree_path: nil))
        .and_return(provision_service)
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "conf123", container_host: "local"),
        container_running?: false,
        container_status: { running: false, exit_code: 0, oom_killed: false, memory_limit_bytes: 1024 },
        cleanup: nil
      )
      allow(provision_service).to receive(:execute) do |_, **_, &block|
        block&.call(:stdout, "conformance output\n")
        Containers::Provision::Result.success(stdout: "conformance output\n", stderr: "", exit_code: 0)
      end
    end
  end
end
