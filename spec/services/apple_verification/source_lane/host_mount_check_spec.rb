# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-003
RSpec.describe AppleVerification::SourceLane::HostMountCheck do
  let(:agent_run) { create(:agent_run, container_id: "agent-container", container_host: "local") }
  let(:backend) { instance_double(Containers::Backends::LocalDocker) }
  let(:container) { instance_double(Docker::Container, info: { "Mounts" => mounts }) }
  let(:mounts) { [] }

  before do
    allow(Containers).to receive(:backend_for).with("local").and_return(backend)
    allow(backend).to receive(:get_container).with("agent-container").and_return(container)
  end

  it "rejects a writable host bind mounted at the agent workspace" do
    mounts << { "Type" => "bind", "Destination" => "/workspace", "RW" => true }

    expect(described_class.call(agent_run)).to be(true)
  end

  it "accepts a named workspace volume and read-only host mounts" do
    mounts.concat([
      { "Type" => "volume", "Destination" => "/workspace", "RW" => true },
      { "Type" => "bind", "Destination" => "/workspace", "RW" => false }
    ])

    expect(described_class.call(agent_run)).to be(false)
  end

  it "fails closed when the agent container cannot be inspected" do
    allow(backend).to receive(:get_container).and_raise(Docker::Error::NotFoundError, "missing")

    expect { described_class.call(agent_run) }
      .to raise_error(described_class::InspectionUnavailableError, /cannot inspect/)
  end

  it "fails closed for a malformed mount table" do
    allow(container).to receive(:info).and_return({ "Mounts" => "unknown" })

    expect { described_class.call(agent_run) }
      .to raise_error(described_class::InspectionUnavailableError, /invalid/)
  end

  it "fails closed when the attempt has no originating container" do
    agent_run.update!(container_id: nil)

    expect { described_class.call(agent_run) }
      .to raise_error(described_class::InspectionUnavailableError, /unavailable/)
  end
end
