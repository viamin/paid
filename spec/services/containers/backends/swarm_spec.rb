# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::Swarm, :no_db do
  subject(:backend) do
    described_class.new(
      manager_host: manager_url,
      connection_options: { client_cert: "/tmp/cert.pem" },
      placement_constraints: "node.labels.paid.agent == true,node.labels.paid.memory != low",
      placement_preferences: "node.labels.paid.zone"
    )
  end

  let(:manager_url) { "https://swarm-manager.internal:2376" }
  let(:service_id) { "svc-123" }
  let(:node_id) { "node-1" }
  let(:container_id) { "container-123" }
  let(:worker_url) { "https://worker-1.internal:2376" }
  let(:service_payload) do
    {
      "ID" => service_id,
      "Spec" => {
        "Name" => "paid-agent",
        "Labels" => { "paid.agent_run_id" => "42" },
        "TaskTemplate" => {
          "ContainerSpec" => {
            "Labels" => { "paid.agent_run_id" => "42" }
          }
        }
      }
    }
  end
  let(:task_payload) do
    {
      "ID" => "task-1",
      "NodeID" => node_id,
      "DesiredState" => "running",
      "Status" => {
        "State" => "running",
        "ContainerStatus" => {
          "ContainerID" => container_id,
          "ExitCode" => 0
        }
      },
      "Version" => { "Index" => 3 }
    }
  end
  let(:node_payload) do
    {
      "ID" => node_id,
      "Spec" => {
        "Availability" => "active",
        "Labels" => {
          "paid.docker_host" => "worker-1.internal"
        }
      },
      "Status" => {
        "State" => "ready",
        "Addr" => "10.0.0.25"
      },
      "Description" => {
        "Hostname" => "worker-1"
      }
    }
  end
  let(:container_payload) do
    {
      "Id" => container_id,
      "Name" => "paid-agent.1",
      "Config" => { "Labels" => {} },
      "State" => { "Running" => true, "ExitCode" => 0 }
    }
  end
  let(:concrete_container) { instance_double(Docker::Container, exec: [ [ "ok" ], [], 0 ], json: container_payload) }

  before do
    stub_manager_get("/services/#{service_id}", service_payload)
    stub_manager_get("/tasks", [ task_payload ], query: hash_including("filters" => /#{service_id}/))
    stub_manager_get("/nodes", [ node_payload ])
    stub_manager_get("/nodes/#{node_id}", node_payload)

    allow(Docker::Container).to receive(:get)
      .with(container_id, {}, kind_of(Docker::Connection))
      .and_return(concrete_container)
  end

  it "reports the swarm backend identifier" do
    expect(backend.identifier).to eq("swarm")
  end

  it "does not advertise host path support" do
    expect(backend.supports_host_paths?).to be(false)
  end

  it "treats the landing node hostname as belonging to the active swarm backend" do
    expect(backend.owns_host?("worker-1")).to be(true)
    expect(backend.owns_host?("other-host")).to be(false)
  end

  it "creates single-replica services with swarm placement and overlay networking" do
    payload = nil
    request = stub_request(:post, "#{manager_url}/services/create")
      .with do |http_request|
        payload = JSON.parse(http_request.body)
        true
      end
      .to_return(status: 200, body: { "ID" => service_id }.to_json)

    service = backend.create_container(container_config)

    expect_service_spec(payload)
    expect(request).to have_been_requested
    expect(service).to be_a(described_class::ServiceHandle)
    expect(backend.container_host_for(service)).to eq("worker-1")
  end

  it "executes commands against the landed task container on the worker node" do
    service = backend.get_container(service_id)

    expect(backend.exec_in_container(service, [ "pwd" ])).to eq([ [ "ok" ], [], 0 ])
    expect(Docker::Container).to have_received(:get).with(container_id, {}, kind_of(Docker::Connection)).at_least(:once)
  end

  it "returns service state based on the current swarm task" do
    service = backend.get_container(service_id)

    expect(service.info.dig("State", "Running")).to be(true)
    expect(service.info.dig("Config", "Labels", "paid.agent_run_id")).to eq("42")
  end

  it "builds service handles from provided payloads without re-fetching immediately" do
    backend.get_container(service_id)

    expect(a_request(:get, "#{manager_url}/services/#{service_id}")).to have_been_made.once
    expect(a_request(:get, "#{manager_url}/tasks")
      .with(query: hash_including("filters" => /#{service_id}/))).to have_been_made.once
  end

  def stub_manager_get(path, response, query: nil)
    request = stub_request(:get, "#{manager_url}#{path}")
    request = request.with(query: query) if query
    request.to_return(status: 200, body: response.to_json)
  end

  def container_config
    {
      "Image" => "paid-agent:latest",
      "name" => "paid-agent",
      "Labels" => { "paid.agent_run_id" => "42" },
      "Cmd" => [ "tail", "-f", "/dev/null" ],
      "Env" => [ "HOME=/home/agent" ],
      "WorkingDir" => "/workspace",
      "User" => "agent",
      "ReadonlyRootfs" => true,
      "CapAdd" => [ "NET_RAW" ],
      "CapDrop" => [ "ALL" ],
      "OpenStdin" => false,
      "Tty" => false,
      "HostConfig" => {
        "Memory" => 4 * 1024 * 1024 * 1024,
        "CpuQuota" => 200_000,
        "CpuPeriod" => 100_000,
        "NetworkMode" => "paid_agent",
        "Binds" => [ "paid-workspace-42:/workspace:rw" ],
        "Tmpfs" => { "/tmp" => "exec,size=1048576,mode=1777" }
      }
    }
  end

  def expect_service_spec(payload)
    expect(payload).to include(
      "Name" => "paid-agent",
      "Mode" => { "Replicated" => { "Replicas" => 1 } },
      "Networks" => [ { "Target" => "paid_agent" } ]
    )
    expect(payload.dig("TaskTemplate", "RestartPolicy")).to eq("Condition" => "none")
    expect(payload.dig("TaskTemplate", "Placement", "Constraints")).to eq([
      "node.labels.paid.agent == true",
      "node.labels.paid.memory != low"
    ])
    expect(payload.dig("TaskTemplate", "Placement", "Preferences")).to eq([
      { "Spread" => { "SpreadDescriptor" => "node.labels.paid.zone" } }
    ])
  end
end
