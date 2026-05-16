# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Provision, ".reconnect", :no_db do
  let(:project) { double(id: 123) }
  let(:agent_run) do
    double(
      id: 456,
      project: project,
      container_host: "remote",
      log!: nil
    )
  end
  let(:container_id) { "claimed-pool-container" }
  let(:container) do
    instance_double(
      Docker::Container,
      id: container_id,
      refresh!: true,
      info: { "State" => { "Running" => true, "ExitCode" => 0 } }
    )
  end
  let(:volume) { instance_double(Docker::Volume) }
  let(:claimed_scope) { double(find_by: nil) }
  let(:container_pool_entry_class) do
    Class.new do
      class << self
        attr_accessor :claimed_scope

        def claimed
          claimed_scope
        end
      end
    end
  end
  let(:remote_backend) do
    instance_double(
      Containers::Backends::Base,
      get_container: container,
      stop_container: true,
      delete_container: true,
      get_volume: volume,
      delete_volume: true
    )
  end

  before do
    container_pool_entry_class.claimed_scope = claimed_scope
    stub_const("ContainerPoolEntry", container_pool_entry_class)
    allow(AgentRuns::UserSettingsResolver).to receive(:call).and_return(nil)
    allow(Containers).to receive(:backend_for).with("remote").and_return(remote_backend)
  end

  it "uses the resolved backend for later lifecycle calls after reconnect" do
    reconnected = described_class.reconnect(agent_run: agent_run, container_id: container_id)
    reconnected.cleanup(force: true)

    expect(Containers).to have_received(:backend_for).with("remote")
    expect(remote_backend).to have_received(:get_container).with(container_id)
    expect(remote_backend).to have_received(:stop_container).with(container, timeout: 0)
    expect(remote_backend).to have_received(:delete_container).with(container, force: true, v: true)
    expect(remote_backend).to have_received(:get_volume).with("paid-workspace-456", host: "remote")
    expect(remote_backend).to have_received(:delete_volume).with(volume)
  end
end
