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

  before do
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
end
