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
    agent_run.update!(external_metadata: {
      "container_host_selection" => {
        "preferred_host" => "elguapo",
        "fallback" => "first_healthy"
      }
    })
    allow(Containers::Provision).to receive(:compatibility_for)
      .with(agent_run: agent_run, backend: elguapo_backend, worktree_path: nil)
      .and_return(Containers::Provision::CompatibilityResult.new(compatible: false, error_message: "elguapo unavailable"))

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.selection_source).to eq("preferred")
    expect(result.candidate_hosts).to eq([ "local", "aws-runner-1" ])
    expect(result.compatibility_failures).to include("elguapo" => "elguapo unavailable")
  end

  it "drops an unhealthy preferred host and falls back to a healthy alternative" do
    agent_run.update!(external_metadata: {
      "container_host_selection" => {
        "preferred_host" => "elguapo",
        "fallback" => "first_healthy"
      }
    })
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

  it "returns an empty candidate list when no host is configured or healthy" do
    agent_run.update!(external_metadata: {
      "container_host_selection" => {
        "preferred_host" => "elguapo",
        "fallback" => "first_healthy"
      }
    })
    allow(local_backend).to receive(:ping).and_raise(Docker::Error::DockerError, "local down")
    allow(aws_backend).to receive(:ping).and_raise(Docker::Error::DockerError, "aws down")
    allow(elguapo_backend).to receive(:ping).and_raise(Docker::Error::DockerError, "elguapo down")

    result = described_class.call(agent_run: agent_run, registry: registry)

    expect(result.candidate_hosts).to eq([])
    expect(result.health_failures.keys).to contain_exactly("elguapo", "local", "aws-runner-1")
  end
end
