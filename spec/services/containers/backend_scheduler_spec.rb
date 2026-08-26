# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::BackendScheduler do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :queued, project: project) }
  let(:local_backend) { instance_double(Containers::Backends::LocalDocker, identifier: "local") }
  let(:elguapo_backend) { instance_double(Containers::Backends::RemoteDocker, identifier: "elguapo") }
  let(:aws_backend) { instance_double(Containers::Backends::RemoteDocker, identifier: "aws-runner-1") }
  let(:registry) do
    Containers::HostRegistry::Registry.new(
      default_host: "local",
      fallback_policy: "first_healthy",
      hosts: [
        Containers::HostRegistry::HostDefinition.new(identifier: "local", backend: local_backend, max_concurrent_runs: 2, fallback_enabled: true),
        Containers::HostRegistry::HostDefinition.new(identifier: "elguapo", backend: elguapo_backend, max_concurrent_runs: 4, fallback_enabled: true),
        Containers::HostRegistry::HostDefinition.new(identifier: "aws-runner-1", backend: aws_backend, max_concurrent_runs: 8, fallback_enabled: true)
      ]
    )
  end

  def healthy_backend(identifier)
    instance_double(Containers::Backends::LocalDocker,
      identifier: identifier,
      ping: true)
  end

  def preferred_host_selection
    {
      "container_host_selection" => {
        "preferred_host" => "elguapo",
        "fallback" => "first_healthy"
      }
    }
  end

  def expect_cached_requirements_for(agent_run:, requested_resources:, provisioner:, requirements:)
    expect(Capacity::RequestedResources).to have_received(:for_agent_run).once.with(agent_run)
    expect(provisioner).to have_received(:service_declarations).once.with(agent_run)
    expect(ExecutionRunners::CapabilityRequirements).to have_received(:from_agent_run).once.with(
      agent_run,
      worktree_path: nil,
      service_declarations: [],
      requested_resources: requested_resources,
      architecture: "arm64"
    )
    expect(Containers::Provision).to have_received(:compatibility_for).exactly(3).times do |args|
      expect(args[:requirements]).to equal(requirements)
    end
  end

  before do
    # RDR-048 health-check contract: BackendScheduler calls ping on every
    # candidate backend (except explicitly-pinned hosts). Stub all backends
    # in the registry to return a healthy result so the existing fallback
    # semantics are exercised before health-specific tests run.
    allow(local_backend).to receive(:ping).and_return(true)
    allow(elguapo_backend).to receive(:ping).and_return(true)
    allow(aws_backend).to receive(:ping).and_return(true)
    allow(Containers::Provision).to receive(:compatibility_for)
      .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
  end

  it "keeps explicit host selection pinned to that host" do
    agent_run.update!(external_metadata: { "container_host_selection" => { "explicit_host" => "elguapo" } })

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.selection_source).to eq("explicit")
    expect(result.candidate_hosts).to eq([ "elguapo" ])
  end

  it "falls back to the next compatible host for preferred host placement" do
    agent_run.update!(external_metadata: preferred_host_selection)
    allow(Containers::Provision).to receive(:compatibility_for)
      .with(hash_including(agent_run: agent_run, backend: elguapo_backend, worktree_path: nil))
      .and_return(Containers::Provision::CompatibilityResult.new(compatible: false, error_message: "elguapo unavailable"))

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.selection_source).to eq("preferred")
    expect(result.candidate_hosts).to eq([ "local", "aws-runner-1" ])
    expect(result.compatibility_failures).to include("elguapo" => "elguapo unavailable")
  end

  it "drops an unhealthy preferred host and falls back to a healthy alternative" do
    agent_run.update!(external_metadata: preferred_host_selection)
    allow(elguapo_backend).to receive(:ping).and_raise(Docker::Error::DockerError, "connection refused")

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.selection_source).to eq("preferred")
    expect(result.candidate_hosts).to eq([ "local", "aws-runner-1" ])
    expect(result.health_failures.keys).to include("elguapo")
  end

  it "does not call ping for explicitly-pinned hosts" do
    agent_run.update!(external_metadata: { "container_host_selection" => { "explicit_host" => "elguapo" } })

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.candidate_hosts).to eq([ "elguapo" ])
    expect(elguapo_backend).not_to have_received(:ping)
  end

  # @spec EXEC-DISABLE-004
  it "excludes a candidate host that has an active backend-scoped execution control" do
    docker_host = create(:docker_host, account: project.account, identifier: "elguapo")
    create(:execution_control, :backend_scope, :enabled, docker_host: docker_host)
    agent_run.update!(external_metadata: preferred_host_selection)

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.selection_source).to eq("preferred")
    expect(result.candidate_hosts).to eq([ "local", "aws-runner-1" ])
    expect(result.compatibility_failures).to include("elguapo" => "Host elguapo is disabled by an execution control")
  end

  it "returns an empty candidate list when no host is configured or healthy" do
    agent_run.update!(external_metadata: preferred_host_selection)
    allow(local_backend).to receive(:ping).and_raise(Docker::Error::DockerError, "local down")
    allow(aws_backend).to receive(:ping).and_raise(Docker::Error::DockerError, "aws down")
    allow(elguapo_backend).to receive(:ping).and_raise(Docker::Error::DockerError, "elguapo down")

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.candidate_hosts).to eq([])
    expect(result.health_failures.keys).to contain_exactly("elguapo", "local", "aws-runner-1")
  end

  # @spec CONTAINER-RUNTIME-043
  # @spec IMMUTABLE-IMAGE-001
  it "contains runtime image selection errors as compatibility failures for every candidate host" do
    agent_run.update!(external_metadata: preferred_host_selection)
    allow(ExecutionRunners::RunSpec).to receive(:resolve_architecture)
      .with(agent_run)
      .and_raise(Containers::RuntimeImageCatalog::InactiveImageError, "Runtime image reference \"retired\" is deprecated")

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.candidate_hosts).to eq([])
    expect(result.compatibility_failures).to eq(
      "elguapo" => "Runtime image reference \"retired\" is deprecated",
      "local" => "Runtime image reference \"retired\" is deprecated",
      "aws-runner-1" => "Runtime image reference \"retired\" is deprecated"
    )
    expect(Containers::Provision).not_to have_received(:compatibility_for)
  end

  # @spec CONTAINER-RUNTIME-043
  it "derives capability requirements once per scheduling pass and reuses them for every candidate host" do
    agent_run.update!(external_metadata: preferred_host_selection)
    requested_resources = Capacity::RequestedResources.for_agent_run(agent_run)
    requirements = ExecutionRunners::CapabilityRequirements.new(capabilities: [ :streaming_logs ])
    provisioner = instance_double(Containers::ServiceProvisioner, service_declarations: [])

    allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
    allow(Capacity::RequestedResources).to receive(:for_agent_run).and_return(requested_resources)
    allow(ExecutionRunners::RunSpec).to receive(:resolve_architecture).with(agent_run).and_return("arm64")
    allow(ExecutionRunners::CapabilityRequirements).to receive(:from_agent_run)
      .and_return(requirements)

    described_class.call(agent_run: agent_run, registry: registry)

    expect_cached_requirements_for(
      agent_run: agent_run,
      requested_resources: requested_resources,
      provisioner: provisioner,
      requirements: requirements
    )
  end
end
