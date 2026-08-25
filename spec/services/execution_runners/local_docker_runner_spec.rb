# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-010
# @spec CONTAINER-RUNTIME-011
# @spec CONTAINER-RUNTIME-017
# @spec CONTAINER-RUNTIME-019
# @spec CONTAINER-RUNTIME-020
# @spec CONTAINER-RUNTIME-025
# @spec CONTAINER-RUNTIME-026
# @spec CONTAINER-RUNTIME-027
# @spec CONTAINER-RUNTIME-028
# @spec EXEC-INGRESS-001
# @spec EXEC-INGRESS-002
RSpec.describe ExecutionRunners::LocalDockerRunner do
  subject(:runner) { described_class.new }

  let(:agent_run) { create(:agent_run, container_host: "local") }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:resources) do
    ExecutionRunners::ExecutionResources.new(
      cpu_cores: 1.0,
      memory_mib: 1024,
      disk_gb: 2,
      architecture: "x86_64",
      timeout_seconds: 3600
    )
  end
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
  let(:firewall_calls) { [] }
  let(:gateway_container) do
    instance_double(Docker::Container,
      info: { "NetworkSettings" => { "Networks" => { "paid_agent" => { "Aliases" => [ "egress-gateway" ] } } } })
  end
  let(:ownership_label_map) do
    ExecutionRunners::OwnershipTags.for(
      agent_run: agent_run, resource_kind: "container", environment: "test"
    ).to_label_map
  end

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

  def stub_ready_gateway_adapter!
    adapter = instance_double(
      AgentRuns::EgressPolicy::GatewayAdapters::Docker,
      gateway_url: "egress-gateway:3128",
      allowlist_for: [],
      ensure!: nil,
      install_allowlist!: nil,
      remove_allowlist!: nil
    )
    allow(described_class).to receive(:gateway_adapter).and_return(adapter)
  end

  before do
    allow(Containers).to receive(:backend_for).and_return(backend)
    allow(NetworkPolicy).to receive(:ensure_network!).and_return(instance_double(Docker::Network))
    allow(NetworkPolicy).to receive(:apply_firewall_rules) do |*args, **kwargs|
      firewall_calls << { args: args, kwargs: kwargs }
    end
    allow(provision_service).to receive_messages(
      firewall_service_destinations: [],
      container: started_container
    )
  end

  describe "#provision" do
    it "delegates to Containers::Provision and returns a RunnerHandle" do
      expect(Containers::Provision).to receive(:new).with(
        agent_run: agent_run, project: agent_run.project, worktree_path: nil, backend: backend,
        networking_policy: run_spec.networking_policy,
        ownership_labels: ownership_label_map,
        egress_gateway_url: nil,
        image: "paid/agent:latest", memory_bytes: 1024 * 1024 * 1024, cpu_quota: 100_000, pids_limit: 500,
        timeout_seconds: 3600
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
        "agent_run_id" => agent_run.id, "worktree_path" => nil, "environment" => { "FOO" => "bar" },
        "timeout_seconds" => 3600
      )
    end

    # @spec CONTAINER-RUNTIME-027
    it "forwards the requested timeout to the provisioner instead of the 3600s default" do
      short_timeout_spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        resources: resources.with(timeout_seconds: 600)
      ))

      expect(Containers::Provision).to receive(:new)
        .with(hash_including(timeout_seconds: 600))
        .and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(runner.provision(spec: short_timeout_spec).metadata["timeout_seconds"]).to eq(600)
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
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: nil, timeout_seconds: 3600)
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

    it "does not thread the egress gateway into :no_outbound runs even when a snapshot exists" do
      no_outbound_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.no_outbound
        )
      )
      seed_snapshot!(mode: "no_outbound")
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(Containers::Provision).to receive(:new)
        .with(hash_including(egress_gateway_url: nil))
        .and_return(provision_service)
      expect(NetworkPolicy).to receive(:apply_firewall_rules)
        .with(started_container, github_ips: [], proxy_host: false,
              service_destinations: [], backend: backend)

      runner.provision(spec: no_outbound_spec)
    end

    it "does not thread the egress gateway into :proxy_only runs even when a snapshot exists" do
      proxy_only_spec = ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.proxy_only
        )
      )
      seed_snapshot!(mode: "proxy_only")
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )

      expect(Containers::Provision).to receive(:new)
        .with(hash_including(egress_gateway_url: nil))
        .and_return(provision_service)
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
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
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
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
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
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
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
        allowlist_for: []
      )
      allow(adapter).to receive(:ensure!).with(agent_run: agent_run, snapshot: kind_of(AgentRuns::EgressPolicy::Snapshot), backend: backend)
      allow(adapter).to receive(:install_allowlist!).with(agent_run: agent_run, snapshot: kind_of(AgentRuns::EgressPolicy::Snapshot), backend: backend)
      allow(adapter).to receive(:remove_allowlist!).with(agent_run: agent_run, backend: backend)
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
    it "removes the gateway allowlist when gateway setup fails after the gateway object is built" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      seed_snapshot!
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        gateway_url: "egress-gateway:3128",
        allowlist_for: []
      )
      allow(adapter).to receive(:ensure!).and_raise(
        AgentRuns::EgressPolicy::Gateway::UnavailableError, "allowlist write failed after partial install"
      )
      allow(adapter).to receive(:remove_allowlist!).with(agent_run: agent_run, backend: backend)
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)

      expect(Containers::Provision).not_to receive(:new)
      expect(adapter).to receive(:remove_allowlist!).with(agent_run: agent_run, backend: backend)

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
        allowlist_for: [],
        remove_allowlist!: nil
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

    # @spec EGRESS-POLICY-007
    it "removes the gateway allowlist when later provisioning steps fail after gateway setup" do
      seed_snapshot!
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        ensure!: nil,
        install_allowlist!: nil,
        gateway_url: "egress-gateway:3128",
        remove_allowlist!: nil
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      allow(NetworkPolicy).to receive(:ensure_network!).and_raise(NetworkPolicy::Error, "Failed to create agent network")

      expect(adapter).to receive(:remove_allowlist!).with(agent_run: agent_run, backend: backend)

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /Network setup failed/)
    end

    # @spec EGRESS-POLICY-007
    it "best-effort logs gateway allowlist cleanup failures without masking the original error" do
      seed_snapshot!
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        ensure!: nil,
        install_allowlist!: nil,
        gateway_url: "egress-gateway:3128"
      )
      allow(adapter).to receive(:remove_allowlist!).and_raise("sidecar unavailable")
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      allow(NetworkPolicy).to receive(:ensure_network!).and_raise(NetworkPolicy::Error, "Failed to create agent network")

      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "container.egress_gateway.cleanup_failed", agent_run_id: agent_run.id, error: "sidecar unavailable")
      )

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /Network setup failed/)
    end
  end

  # @spec CONTAINER-RUNTIME-025
  # @spec CONTAINER-RUNTIME-026
  # @spec CONTAINER-RUNTIME-027
  describe "provisioning ledger integration (RDR-060)" do
    before do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )
    end

    it "records a pending intent before the create call, then links the resource and handle" do
      intents_at_create = []
      allow(provision_service).to receive(:provision) do
        intents_at_create.concat(ProvisioningIntent.where(status: "pending").to_a)
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      end

      handle = runner.provision(spec: run_spec)

      expect(intents_at_create).not_to be_empty
      expect(intents_at_create.first).to be_pending
      intent = ProvisioningIntent.order(:id).last
      expect(intent.status).to eq("linked")
      expect(intent.provider_resource_id).to eq("abc123")
      expect(intent.runner_handle).to eq(handle.to_storage)
      expect(intent.runner_type).to eq("local_docker")
      expect(intent.resource_kind).to eq("container")
      expect(intent.tagging_supported).to be(true)
    end

    it "passes the stable Paid ownership labels through to Containers::Provision" do
      expect(Containers::Provision).to receive(:new).with(
        hash_including(ownership_labels: ownership_label_map)
      ).and_return(provision_service)

      runner.provision(spec: run_spec)
    end

    it "increments the provisioning attempt ordinal across repeated provisions for the same run" do
      first_handle = runner.provision(spec: run_spec)
      second_handle = runner.provision(spec: run_spec)

      intents = ProvisioningIntent.order(:id).last(2)

      expect(first_handle.identifier).to eq("abc123")
      expect(second_handle.identifier).to eq("abc123")
      expect(intents.map(&:attempt)).to eq([ 0, 1 ])
      expect(intents.map { |intent| intent.ownership_tags.fetch("paid.attempt") }).to eq(%w[0 1])
    end

    it "fails loudly instead of duplicating a ledger row when two provisions race for the same attempt ordinal" do
      # ExecutionRunners::ProvisioningLedger#next_attempt_for (count) then
      # #record_intent (create!) is not atomic, so two concurrent retries can
      # both observe attempt 0. The unique index on
      # (agent_run_id, resource_kind, attempt) is the concurrency guard: the
      # second writer must raise instead of silently persisting a duplicate.
      first_ledger = runner.send(:provisioning_ledger)
      second_ledger = runner.send(:provisioning_ledger)
      attempt = first_ledger.next_attempt_for(agent_run: agent_run)
      expect(second_ledger.next_attempt_for(agent_run: agent_run)).to eq(attempt)

      first_ledger.record_intent(agent_run: agent_run, attempt: attempt)

      expect { second_ledger.record_intent(agent_run: agent_run, attempt: attempt) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "marks the intent failed when the provider create call fails" do
      allow(provision_service).to receive(:provision)
        .and_raise(Containers::Provision::ProvisionError, "Docker error: no space left")

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /no space left/)

      intent = ProvisioningIntent.order(:id).last
      expect(intent.status).to eq("failed")
      expect(intent.provider_resource_id).to be_nil
    end

    it "keeps the intent reconcileable when cleanup also fails after a post-create runner error" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      seed_snapshot!
      stub_ready_gateway_adapter!
      allow(NetworkPolicy).to receive(:apply_firewall_rules)
        .and_raise(NetworkPolicy::Error, "iptables not available")
      allow(provision_service).to receive_messages(agent_run: agent_run, cleanup: nil)
      allow(provision_service).to receive(:cleanup).and_raise(StandardError, "docker daemon unavailable")

      expect { runner.provision(spec: run_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /Firewall setup failed/)

      intent = ProvisioningIntent.order(:id).last
      expect(intent.status).to eq("created")
      expect(intent.provider_resource_id).to eq("abc123")
      expect(intent).to be_orphaned
    end
  end

  # @spec CONTAINER-RUNTIME-027
  describe "crash-window reconciliation (RDR-060)" do
    it "leaves a created ledger row with the resource id when the process dies after provider creation" do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )
      # A fresh runner instance simulates a worker crash after the provider
      # resource is created but before the runner handle is built/persisted.
      crashing_runner = described_class.new
      allow(crashing_runner).to receive(:handle_for).and_raise(StandardError, "worker killed mid-provision")

      expect { crashing_runner.provision(spec: run_spec) }.to raise_error(StandardError, /worker killed/)

      intent = ProvisioningIntent.order(:id).last
      expect(intent.status).to eq("created")
      expect(intent.provider_resource_id).to eq("abc123")
      expect(intent.provider_resource_host).to eq("local")
      expect(intent.runner_handle).to be_blank
      expect(intent).to be_orphaned
      # Reconciliation can locate the live resource by tag even without the
      # persisted runner handle.
      expect(intent.ownership_tags).to include(
        "paid.run" => agent_run.id.to_s,
        "paid.resource" => "container"
      )
    end
  end

  # @spec CONTAINER-RUNTIME-026
  describe "degradation when tagging is unsupported (RDR-060)" do
    let(:untagging_runner) do
      Class.new(described_class) { def supports_tagging?; false; end }.new
    end

    before do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )
    end

    it "still provisions, records tagging_supported=false, and applies no ownership labels" do
      expect(Containers::Provision).to receive(:new).with(
        hash_including(ownership_labels: {})
      ).and_return(provision_service)

      expect { untagging_runner.provision(spec: run_spec) }.not_to raise_error

      intent = ProvisioningIntent.order(:id).last
      expect(intent.tagging_supported).to be(false)
      expect(intent.metadata).to include("tagging_degraded" => true)
      expect(intent.ownership_tags).to be_empty
    end

    it "emits a warning so the degradation is observable" do
      seed_snapshot!
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        gateway_url: "egress-gateway:3128",
        allowlist_for: [],
        ensure!: nil,
        install_allowlist!: nil
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "execution_runners.tagging_unsupported_degraded")
      )

      untagging_runner.provision(spec: run_spec)
    end
  end

  # @spec CONTAINER-RUNTIME-026
  describe "degradation when listing is unsupported (RDR-060)" do
    let(:unlisting_runner) do
      Class.new(described_class) { def supports_listing?; false; end }.new
    end

    before do
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(
        Containers::Provision::Result.success(container_id: "abc123", container_host: "local")
      )
    end

    it "still provisions and records the explicit listing degradation on the ledger row" do
      expect { unlisting_runner.provision(spec: run_spec) }.not_to raise_error

      intent = ProvisioningIntent.order(:id).last
      expect(intent.ownership_tags).to include("paid.run" => agent_run.id.to_s)
      expect(intent.metadata).to include("listing_degraded" => true)
      expect(intent.metadata.fetch("reason")).to include("runner_or_provider_cannot_list")
    end

    it "emits a warning so the degradation is observable" do
      seed_snapshot!
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        gateway_url: "egress-gateway:3128",
        allowlist_for: [],
        ensure!: nil,
        install_allowlist!: nil
      )
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "execution_runners.listing_unsupported_degraded")
      )

      unlisting_runner.provision(spec: run_spec)
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

    # @spec CONTAINER-RUNTIME-027
    it "threads the requested timeout from the handle metadata so a reconnected run keeps it" do
      timed_handle = handle.with(metadata: handle.metadata.merge("timeout_seconds" => 600))

      expect(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: nil, timeout_seconds: 600)
        .and_return(provision_service)

      runner.reconnect(handle: timed_handle)
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

    it "tears down the container before draining the gateway state" do
      seed_snapshot!(destinations: [ { "host" => "evil.example.com", "port" => 443, "source" => "project_allowlist" } ])
      adapter = stub_gateway_collect_denials!(
        host: "evil.example.com", port: 443, matched_rule: "no matching rule", scheme: "https"
      )
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(Containers).to receive(:backend_for).with("local").and_return(backend)

      expect(provision_service).to receive(:cleanup).ordered.with(force: true)
      expect(adapter).to receive(:collect_denials).ordered.with(agent_run: agent_run, backend: backend)
      expect(adapter).to receive(:remove_allowlist!).ordered.with(agent_run: agent_run, backend: backend)

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
    it "removes the run's allowlist from the gateway sidecar so it does not accumulate stale files" do
      seed_snapshot!(destinations: [ { "host" => "evil.example.com", "port" => 443, "source" => "project_allowlist" } ])
      adapter = stub_gateway_collect_denials!(
        host: "evil.example.com", port: 443, matched_rule: "no matching rule", scheme: "https"
      )
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      allow(Containers).to receive(:backend_for).with("local").and_return(backend)

      runner.cleanup(handle: handle, force: true)

      expect(adapter).to have_received(:remove_allowlist!).with(agent_run: agent_run, backend: backend)
    end

    # @spec EGRESS-POLICY-007
    it "skips the gateway drain for runs with no persisted snapshot" do
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker)
      expect(adapter).not_to receive(:collect_denials)
      expect(adapter).not_to receive(:remove_allowlist!)
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
      expect(adapter).not_to receive(:remove_allowlist!)
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)

      expect { runner.cleanup(handle: handle, force: true) }.not_to change(EgressSecurityEvent, :count)
    end

    # @spec EGRESS-POLICY-007
    it "logs a warning but never raises when the gateway drain itself fails" do
      seed_snapshot!(destinations: [ { "host" => "evil.example.com", "port" => 443, "source" => "project_allowlist" } ])
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker, remove_allowlist!: nil)
      allow(adapter).to receive(:collect_denials).and_raise(StandardError, "sidecar exec failed")
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      allow(Containers).to receive(:backend_for).with("local").and_return(backend)

      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "container.gateway.denial_drain_failed", agent_run_id: agent_run.id)
      )

      expect { runner.cleanup(handle: handle, force: true) }.not_to raise_error
    end

    # @spec EGRESS-POLICY-007
    it "still attempts allowlist removal when denial draining fails" do
      seed_snapshot!(destinations: [ { "host" => "evil.example.com", "port" => 443, "source" => "project_allowlist" } ])
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker, remove_allowlist!: nil)
      allow(adapter).to receive(:collect_denials).and_raise(StandardError, "sidecar exec failed")
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)
      allow(Containers).to receive(:backend_for).with("local").and_return(backend)

      expect { runner.cleanup(handle: handle, force: true) }.not_to raise_error

      expect(adapter).to have_received(:remove_allowlist!).with(agent_run: agent_run, backend: backend)
    end

    # @spec EGRESS-POLICY-007
    it "logs a warning but never raises when the allowlist removal itself fails" do
      seed_snapshot!(destinations: [ { "host" => "evil.example.com", "port" => 443, "source" => "project_allowlist" } ])
      allow(Containers::Provision).to receive(:reconnect).and_return(provision_service)
      allow(provision_service).to receive(:cleanup)
      adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker, collect_denials: [])
      allow(adapter).to receive(:remove_allowlist!).and_raise(StandardError, "sidecar exec failed")
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
      expect(adapter).not_to receive(:remove_allowlist!)
      allow(described_class).to receive(:gateway_adapter).and_return(adapter)

      expect { runner.cleanup(handle: no_id_handle, force: true) }.not_to raise_error
    end

    # Builds an instance double for the gateway adapter whose
    # +#collect_denials+ returns a single denial record built from the
    # given kwargs, and whose +#remove_allowlist!+ is stubbed as a no-op.
    # Returns the double so specs can assert against it.
    def stub_gateway_collect_denials!(host:, port:, matched_rule:, scheme:)
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        collect_denials: [ { host: host, port: port, matched_rule: matched_rule, scheme: scheme } ],
        remove_allowlist!: nil
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

  # @spec CONTAINER-RUNTIME-032
  # @spec CONTAINER-RUNTIME-033
  # @spec CONTAINER-RUNTIME-034
  describe "supporting services, MCP sidecars, and the browser container (RDR-054)" do
    describe "#provision_services" do
      it "delegates to Containers::ServiceProvisioner#provision with the same env-var result as today" do
        provisioner = instance_double(Containers::ServiceProvisioner)
        allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
        allow(provisioner).to receive(:provision)
          .with(agent_run, network: "paid_agent")
          .and_return({ "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" })

        env_vars = runner.provision_services(agent_run: agent_run, network: "paid_agent")

        expect(env_vars).to eq({ "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" })
      end
    end

    describe "#cleanup_services" do
      it "delegates to Containers::ServiceProvisioner#cleanup" do
        provisioner = instance_double(Containers::ServiceProvisioner)
        allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
        expect(provisioner).to receive(:cleanup).with(agent_run, stale_requeue_count: 2)

        runner.cleanup_services(agent_run: agent_run, stale_requeue_count: 2)
      end
    end

    describe "#provision_mcp_servers" do
      it "delegates to Containers::McpProvisioner#provision" do
        provisioner = instance_double(Containers::McpProvisioner)
        allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
        allow(provisioner).to receive(:provision)
          .with(agent_run, network: "paid_agent")
          .and_return(stdio_servers: [], url_servers: [])

        result = runner.provision_mcp_servers(agent_run: agent_run, network: "paid_agent")

        expect(result).to eq(stdio_servers: [], url_servers: [])
      end
    end

    describe "#cleanup_mcp_servers" do
      it "delegates to Containers::McpProvisioner#cleanup" do
        provisioner = instance_double(Containers::McpProvisioner)
        allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
        expect(provisioner).to receive(:cleanup).with(agent_run)

        runner.cleanup_mcp_servers(agent_run: agent_run)
      end
    end

    describe "#provision_browser_container" do
      it "delegates to AgentRuns::Verification.call" do
        result = instance_double(AgentRuns::Verification::Result)
        expect(AgentRuns::Verification).to receive(:call)
          .with(agent_run: agent_run, network: "paid_agent", logger: Rails.logger)
          .and_return(result)

        expect(runner.provision_browser_container(agent_run: agent_run, network: "paid_agent", logger: Rails.logger)).to eq(result)
      end
    end
  end

  describe ".compatible?" do
    it "delegates to Containers::Provision.compatibility_for" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .with(agent_run: agent_run, backend: backend, worktree_path: nil)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)

      result = described_class.compatible?(spec: run_spec, backend: backend)

      expect(result).to be_a(ExecutionRunners::CompatibilityResult)
      expect(result.compatible).to be(true)
    end

    it "supports every RDR-062 networking intent (Docker implements every shape)" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)

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
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
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
    it "accepts :no_outbound without a gateway adapter because it only uses firewall enforcement" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      allow(described_class).to receive(:gateway_adapter).and_return(nil)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.no_outbound
      ))

      result = described_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true)
    end

    # @spec EGRESS-POLICY-007
    it "accepts :proxy_only without a gateway adapter because it only uses firewall enforcement" do
      allow(Containers::Provision).to receive(:compatibility_for)
        .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
      allow(described_class).to receive(:gateway_adapter).and_return(nil)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_only
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
        .with(agent_run: agent_run, container_id: "abc123", worktree_path: nil, timeout_seconds: 3600)
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
      allow(backend).to receive(:get_container).with("egress-gateway").and_return(gateway_container)
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        execute: Containers::Provision::Result.success(stdout: "ok\n", stderr: "", exit_code: 0),
        container_running?: true, container: instance_double(Docker::Container), backend: backend, cleanup: nil
      )
      allow(provision_service).to receive_messages(firewall_service_destinations: [])
    end
  end

  it_behaves_like "an execution runner contract" do
    def assert_workspace_cleanup!
      expect(provision_service).to receive(:cleanup).with(force: true)

      runner.cleanup(handle: valid_handle, force: true)
    end

    let(:contract_abort_patterns) { [ "quota exceeded" ] }
    let(:aborting_contract_command) { "emit quota warning" }
    let(:completed_provision_service) do
      instance_double(
        Containers::Provision,
        container_running?: false
      )
    end

    let(:valid_handle) do
      ExecutionRunners::RunnerHandle.new(
        runner_type: :local_docker,
        identifier: "abc123",
        host: "local",
        workspace_ref: "paid-workspace-#{agent_run.id}",
        metadata: {
          "agent_run_id" => agent_run.id,
          "worktree_path" => nil,
          "environment" => { "FOO" => "bar" },
          "timeout_seconds" => 3600
        }
      )
    end
    let(:missing_handle) { valid_handle.with(identifier: "missing123") }
    let(:unrestricted_run_spec) do
      ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(networking_policy: ExecutionRunners::NetworkingPolicy.direct_outbound)
      )
    end

    let(:restricted_networking_effects) { firewall_calls }
    let(:expected_restricted_networking_effects) do
      [
        {
          args: [ started_container ],
          kwargs: {
            github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
            proxy_host: nil,
            service_destinations: [],
            backend: backend
          }
        }
      ]
    end
    let(:unrestricted_networking_effects) { firewall_calls }
    let(:expected_unrestricted_networking_effects) { [] }

    before do
      allow(Containers::Provision).to receive_messages(
        new: provision_service,
        compatibility_for: Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil)
      )
      allow(provision_service).to receive(:execute) do |command, abort_patterns:, **, &block|
        case command
        when "startup timeout"
          raise Containers::Provision::StartupTimeoutError.new("No output received", diagnostics: { elapsed: 30 })
        when "idle timeout"
          raise Containers::Provision::IdleTimeoutError.new("Output stalled", diagnostics: { idle_seconds: 30 })
        when "wall timeout"
          raise Containers::Provision::TimeoutError.new("Timed out", diagnostics: { elapsed: 60 })
        when aborting_contract_command
          if abort_patterns == contract_abort_patterns
            raise Containers::Provision::OutputAbortError.new("aborted", matched_output: contract_abort_patterns.first,
              source: :pattern)
          end

          block&.call(:stdout, "ok\n")
          Containers::Provision::Result.success(stdout: "ok\n", stderr: "", exit_code: 0)
        when "oom failure"
          Containers::Provision::Result.failure(
            error: "Command exited with code 137",
            stdout: "",
            stderr: "",
            exit_code: 137,
            oom_killed: true,
            memory_limit_bytes: 4_294_967_296,
            container_running: false
          )
        else
          block&.call(:stdout, "ok\n")
          Containers::Provision::Result.success(stdout: "ok\n", stderr: "", exit_code: 0)
        end
      end
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        container_running?: true,
        cleanup: nil,
        container: started_container,
        backend: backend,
        firewall_service_destinations: []
      )
      allow(backend).to receive(:stop_container)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(instance_double(
        Containers::ServiceProvisioner,
        provision: { "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" },
        cleanup: nil
      ))
      allow(NetworkPolicy).to receive(:contract_for_policy).and_call_original
      allow(AgentRun).to receive(:find).and_call_original
      allow(Containers::Provision).to receive(:reconnect) do |agent_run:, container_id:, **kwargs|
        raise Containers::Provision::ProvisionError, "Container #{container_id} not found" if container_id == "missing123"

        container_id == "abc123-completed" ? completed_provision_service : provision_service
      end
    end
  end

  it_behaves_like "a secure execution runner" do
    let(:captured_proxy_scope_credentials) { [] }
    let(:secure_networking_effects) { firewall_calls }
    let(:expected_secure_networking_effects) do
      [
        {
          args: [ started_container ],
          kwargs: {
            github_ips: NetworkPolicy::DEFAULT_GITHUB_IPS,
            proxy_host: nil,
            service_destinations: [],
            backend: backend
          }
        }
      ]
    end

    let(:secure_run_spec) do
      ExecutionRunners::RunSpec.new(
        **run_spec.to_h.merge(
          secrets_config: { "OPENAI_API_KEY" => "sk-test-super-secret" }
        )
      )
    end
    let(:second_agent_run) { create(:agent_run, container_host: "local") }
    let(:second_secure_run_spec) do
      ExecutionRunners::RunSpec.new(
        **secure_run_spec.to_h.merge(
          agent_run: second_agent_run,
          project: second_agent_run.project,
          environment: { "FOO" => "baz" }
        )
      )
    end

    let(:secret_values_excluded_from_handle_metadata) do
      [ "sk-test-super-secret", agent_run.proxy_token ]
    end
    let(:expected_proxy_scope_agent_run_ids) do
      [ agent_run.id, second_agent_run.id ]
    end

    before do
      allow(Containers::Provision).to receive(:new) do |**kwargs|
        run = kwargs.fetch(:agent_run)
        captured_proxy_scope_credentials << { agent_run_id: run.id, proxy_token: run.proxy_token }
        provision_service
      end
      allow(provision_service).to receive_messages(
        provision: Containers::Provision::Result.success(container_id: "abc123", container_host: "local"),
        firewall_service_destinations: []
      )
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
