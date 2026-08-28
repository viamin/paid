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
      "ServiceID" => service_id,
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

  it "uses overlay DNS rather than remote proxy routing" do
    expect(backend.remote?).to be(false)
  end

  it "does not advertise host path support" do
    expect(backend.supports_host_paths?).to be(false)
  end

  it "treats the landing node hostname as belonging to the active swarm backend" do
    expect(backend.owns_host?("worker-1")).to be(true)
    expect(backend.owns_host?("other-host")).to be(false)
  end

  it "includes node hostnames and backend identifier in all_host_identifiers" do
    expect(backend.all_host_identifiers).to contain_exactly("worker-1", "swarm")
  end

  it "aggregates CPU and memory across healthy swarm nodes" do
    stub_manager_get("/nodes", [ node_payload, build_node_payload(id: "node-2", host: "worker-2", addr: "10.0.0.26") ])
    allow(Docker).to receive(:info)
      .with(kind_of(Docker::Connection))
      .and_return(
        { "NCPU" => 4, "MemTotal" => 8_000 },
        { "NCPU" => 8, "MemTotal" => 16_000 }
      )

    expect(backend.system_info).to eq("NCPU" => 12, "MemTotal" => 24_000)
  end

  it "verifies an image is present on every healthy swarm node" do
    second_node = build_node_payload(id: "node-2", host: "worker-2", addr: "10.0.0.26")
    image = instance_double(Docker::Image)

    stub_manager_get("/nodes", [ node_payload, second_node ])
    allow(Docker::Image).to receive(:get)
      .with("paid-agent:latest", {}, kind_of(Docker::Connection))
      .and_return(image, image)

    expect(backend.get_image("paid-agent:latest")).to eq(image)
    expect(Docker::Image).to have_received(:get).twice
  end

  it "returns image labels for every healthy swarm node copy of a tag" do
    second_node = build_node_payload(id: "node-2", host: "worker-2", addr: "10.0.0.26")
    node1_image = instance_double(Docker::Image, info: { "Labels" => { "digest" => "sha256:1" } })
    node2_image = instance_double(Docker::Image, info: { "Labels" => { "digest" => "sha256:2" } })

    stub_manager_get("/nodes", [ node_payload, second_node ])
    allow(Docker::Image).to receive(:get)
      .with("paid-agent:go", {}, kind_of(Docker::Connection))
      .and_return(node1_image, node2_image)

    expect(backend.image_label_sets("paid-agent:go")).to eq(
      [ { "digest" => "sha256:1" }, { "digest" => "sha256:2" } ]
    )
  end

  it "builds an image on every healthy node via docker-api's string-body build API" do
    second_node = build_node_payload(id: "node-2", host: "worker-2", addr: "10.0.0.26")
    node1_image = instance_double(Docker::Image)
    node2_image = instance_double(Docker::Image)

    stub_manager_get("/nodes", [ node_payload, second_node ])
    allow(Docker::Image).to receive(:build)
      .with("FROM scratch", { t: "paid-agent:go" }, kind_of(Docker::Connection))
      .and_return(node1_image, node2_image)

    expect(backend.build_image("FROM scratch", { t: "paid-agent:go" })).to eq([ node1_image, node2_image ])
  end

  it "dedupes images across nodes by repo tag, not per-node image id" do
    second_node = build_node_payload(id: "node-2", host: "worker-2", addr: "10.0.0.26")
    node1_image = instance_double(Docker::Image, id: "sha256:node1", info: { "RepoTags" => [ "paid-agent:python-node" ] })
    node2_image = instance_double(Docker::Image, id: "sha256:node2", info: { "RepoTags" => [ "paid-agent:python-node" ] })

    stub_manager_get("/nodes", [ node_payload, second_node ])
    allow(Docker::Image).to receive(:all).with({}, kind_of(Docker::Connection)).and_return([ node1_image ], [ node2_image ])

    images = backend.list_images

    expect(images).to contain_exactly(node1_image)
  end

  it "raises when a healthy swarm node is missing the image" do
    second_node = build_node_payload(id: "node-2", host: "worker-2", addr: "10.0.0.26")
    image = instance_double(Docker::Image)
    call_count = 0

    stub_manager_get("/nodes", [ node_payload, second_node ])
    allow(Docker::Image).to receive(:get).with("paid-agent:latest", {}, kind_of(Docker::Connection)) do
      call_count += 1
      raise Docker::Error::NotFoundError, "No such image: paid-agent:latest" if call_count == 2

      image
    end

    expect {
      backend.get_image("paid-agent:latest")
    }.to raise_error(Docker::Error::NotFoundError, /worker-2/)
  end

  it "deletes an image on every healthy node, tolerating nodes where the tag never converged" do
    second_node = build_node_payload(id: "node-2", host: "worker-2", addr: "10.0.0.26")
    call_count = 0

    stub_manager_get("/nodes", [ node_payload, second_node ])
    allow(Docker::Image).to receive(:remove).with("paid-agent:python-node", {}, kind_of(Docker::Connection)) do
      call_count += 1
      raise Docker::Error::NotFoundError, "No such image: paid-agent:python-node" if call_count == 2
    end

    expect {
      backend.delete_image("paid-agent:python-node")
    }.not_to raise_error
    expect(Docker::Image).to have_received(:remove).twice
  end

  it "keeps recognizing persisted node hostnames even when the node is not ready" do
    down_node = node_payload.deep_dup
    down_node["Status"]["State"] = "down"
    stub_manager_get("/nodes", [ down_node ])

    expect(backend.owns_host?("worker-1")).to be(true)
  end

  it "caches node hostnames between owns_host? checks for a short ttl" do
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0, 100.0, 131.0)

    expect(backend.owns_host?("worker-1")).to be(true)
    expect(backend.owns_host?("other-host")).to be(false)
    expect(backend.owns_host?("worker-1")).to be(true)

    expect(a_request(:get, "#{manager_url}/nodes")).to have_been_made.twice
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

  it "waits for a runnable task before returning from start_container" do
    pending_task = task_payload.deep_dup
    pending_task["Status"] = { "State" => "pending", "ContainerStatus" => {} }

    stub_request(:get, "#{manager_url}/tasks")
      .with(query: hash_including("filters" => /#{service_id}/))
      .to_return(
        { status: 200, body: [ pending_task ].to_json },
        { status: 200, body: [ pending_task ].to_json },
        { status: 200, body: [ task_payload ].to_json }
      )

    service = backend.get_container(service_id)

    expect(backend.start_container(service)).to eq(service)
    expect(service.task.dig("Status", "ContainerStatus", "ContainerID")).to eq(container_id)
  end

  it "executes commands against the landed task container on the worker node" do
    service = backend.get_container(service_id)

    expect(backend.exec_in_container(service, [ "pwd" ])).to eq([ [ "ok" ], [], 0 ])
    expect(Docker::Container).to have_received(:get).with(container_id, {}, kind_of(Docker::Connection)).at_least(:once)
  end

  it "refreshes the routed task before exec when the service is rescheduled" do
    replacement_task = task_payload.deep_dup
    replacement_task["ID"] = "task-2"
    replacement_task["Version"] = { "Index" => 4 }
    replacement_task["Status"]["ContainerStatus"]["ContainerID"] = "container-456"
    replacement_container = instance_double(Docker::Container, exec: [ [ "moved" ], [], 0 ], json: container_payload)

    allow(Docker::Container).to receive(:get)
      .with("container-456", {}, kind_of(Docker::Connection))
      .and_return(replacement_container)
    stub_request(:get, "#{manager_url}/tasks")
      .with(query: hash_including("filters" => /#{service_id}/))
      .to_return(
        { status: 200, body: [ task_payload ].to_json },
        { status: 200, body: [ replacement_task ].to_json }
      )

    service = backend.get_container(service_id)

    expect(backend.exec_in_container(service, [ "pwd" ])).to eq([ [ "moved" ], [], 0 ])
    expect(service.task.fetch("ID")).to eq("task-2")
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

  it "fetches tasks once when listing multiple services" do
    other_service_id = "svc-456"
    filters = MultiJson.dump(service: [ service_id, other_service_id ])
    other_task = task_payload.deep_dup
    other_task["ID"] = "task-9"
    other_task["ServiceID"] = other_service_id
    other_task["Version"] = { "Index" => 9 }
    other_service = service_payload.deep_dup
    other_service["ID"] = other_service_id
    other_service["Spec"]["Name"] = "paid-agent-2"

    stub_request(:get, "#{manager_url}/services")
      .to_return(status: 200, body: [ service_payload, other_service ].to_json)
    tasks_request = stub_request(:get, "#{manager_url}/tasks")
      .with(query: { "filters" => filters })
      .to_return(status: 200, body: [ task_payload, other_task ].to_json)

    services = backend.list_containers

    expect(services.map(&:service_id)).to eq([ service_id, other_service_id ])
    expect(tasks_request).to have_been_requested.once
  end

  it "detects image usage from service task template images, not a container-list filter" do
    in_use_service = service_payload.deep_dup
    in_use_service["Spec"]["TaskTemplate"]["ContainerSpec"]["Image"] = "paid-agent:go-node"
    other_service = service_payload.deep_dup
    other_service["ID"] = "svc-456"
    other_service["Spec"]["TaskTemplate"]["ContainerSpec"]["Image"] = "paid-agent:ruby-python"
    stub_manager_get("/services", [ in_use_service, other_service ])

    expect(backend.image_in_use?("paid-agent:go-node")).to be(true)
    expect(backend.image_in_use?("paid-agent:unused")).to be(false)
  end

  it "matches a service image resolved to a registry digest by its tag" do
    digested_service = service_payload.deep_dup
    digested_service["Spec"]["TaskTemplate"]["ContainerSpec"]["Image"] =
      "paid-agent:go-node@sha256:#{"a" * 64}"
    stub_manager_get("/services", [ digested_service ])

    expect(backend.image_in_use?("paid-agent:go-node")).to be(true)
  end

  it "includes standalone node-local containers for capacity snapshots without duplicating swarm tasks" do
    stub_manager_get("/services", [ service_payload ])
    standalone = build_listed_container(id: "standalone-1", labels: { "com.example.role" => "db" })
    swarm_task_container = build_listed_container(id: container_id, labels: { "com.docker.swarm.service.id" => service_id })
    allow(Docker::Container).to receive(:all)
      .with({}, kind_of(Docker::Connection))
      .and_return([ swarm_task_container, standalone ])

    containers = backend.list_containers(include_node_containers: true)

    expect(containers.length).to eq(2)
    expect(containers.first).to be_a(described_class::ServiceHandle)
    expect(containers.last).to eq(standalone)
  end

  it "surfaces labels and the owning node hostname for each listed volume" do
    volume = instance_double(Docker::Volume, id: "paid-workspace-42", info: { "Labels" => { "paid.resource" => "workspace_volume" } })
    without_partial_double_verification do
      allow(Docker::Volume).to receive(:all).with({}, kind_of(Docker::Connection)).and_return([ volume ])
    end

    handles = backend.list_volumes

    expect(handles.length).to eq(1)
    expect(handles.first).to have_attributes(
      id: "paid-workspace-42",
      host: "worker-1",
      labels: { "paid.resource" => "workspace_volume" }
    )
  end

  it "looks up volumes on each worker connection" do
    volume = instance_double(Docker::Volume)

    without_partial_double_verification do
      allow(Docker::Volume).to receive(:get)
        .with("paid-workspace-42", {}, kind_of(Docker::Connection))
        .and_return(volume)
    end

    handle = backend.get_volume("paid-workspace-42")

    expect(handle.host).to eq("worker-1")
  end

  it "removes volumes through the owning worker connection" do
    volume = instance_double(Docker::Volume, remove: true)
    without_partial_double_verification do
      allow(Docker::Volume).to receive(:get)
        .with("paid-workspace-42", {}, kind_of(Docker::Connection))
        .and_return(volume)
    end

    backend.delete_volume(
      described_class::VolumeHandle.new(backend: backend, id: "paid-workspace-42", host: "worker-1"),
      force: true
    )

    expect(volume).to have_received(:remove).with(force: true)
  end

  def stub_manager_get(path, response, query: nil)
    request = stub_request(:get, "#{manager_url}#{path}")
    request = request.with(query: query) if query
    request.to_return(status: 200, body: response.to_json)
  end

  def build_node_payload(id:, host:, addr:)
    {
      "ID" => id,
      "Spec" => {
        "Availability" => "active",
        "Labels" => {
          "paid.docker_host" => "#{host}.internal"
        }
      },
      "Status" => {
        "State" => "ready",
        "Addr" => addr
      },
      "Description" => {
        "Hostname" => host
      }
    }
  end

  def build_listed_container(id:, labels:)
    instance_double(
      Docker::Container,
      id: id,
      info: {
        "Id" => id,
        "Labels" => labels,
        "State" => "running"
      }
    )
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
      "SecurityOpt" => [ "no-new-privileges:true" ],
      "OpenStdin" => false,
      "Tty" => false,
      "HostConfig" => {
        "Memory" => 4 * 1024 * 1024 * 1024,
        "CpuQuota" => 200_000,
        "CpuPeriod" => 100_000,
        "PidsLimit" => 4096,
        "SecurityOpt" => [ "no-new-privileges:true" ],
        "NetworkMode" => "paid_agent",
        "Binds" => [ "paid-workspace-42:/workspace:rw" ],
        "Tmpfs" => {
          "/tmp" => "exec,size=1048576,mode=1777",
          "/home/agent/.cache" => "exec,size=536870912,mode=0755"
        }
      }
    }
  end

  it "maps capabilities and no-new-privileges from HostConfig when callers use Docker-style nesting" do
    payload = backend.send(
      :service_spec,
      container_config.deep_merge(
        "CapAdd" => nil,
        "CapDrop" => nil,
        "SecurityOpt" => nil,
        "HostConfig" => {
          "CapAdd" => [ "NET_RAW" ],
          "CapDrop" => [ "ALL" ],
          "SecurityOpt" => [ "no-new-privileges:true" ]
        }
      )
    )

    expect(payload.dig("TaskTemplate", "ContainerSpec", "CapabilityAdd")).to eq([ "NET_RAW" ])
    expect(payload.dig("TaskTemplate", "ContainerSpec", "CapabilityDrop")).to eq([ "ALL" ])
    expect(payload.dig("TaskTemplate", "ContainerSpec", "Privileges")).to eq(
      "NoNewPrivileges" => true
    )
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
    expect(payload.dig("TaskTemplate", "ContainerSpec", "Privileges")).to eq(
      "NoNewPrivileges" => true
    )
    expect(payload.dig("TaskTemplate", "Resources", "Limits", "Pids")).to eq(4096)

    tmpfs_mounts = payload.dig("TaskTemplate", "ContainerSpec", "Mounts").select { |m| m["Type"] == "tmpfs" }
    tmp_mount = tmpfs_mounts.find { |m| m["Target"] == "/tmp" }
    cache_mount = tmpfs_mounts.find { |m| m["Target"] == "/home/agent/.cache" }
    expect(tmp_mount.dig("TmpfsOptions", "Options")).to eq([ "exec" ])
    expect(tmp_mount.dig("TmpfsOptions", "Mode")).to eq(0o1777)
    expect(tmp_mount.dig("TmpfsOptions", "SizeBytes")).to eq(1_048_576)
    expect(cache_mount.dig("TmpfsOptions", "Options")).to eq([ "exec" ])
    expect(cache_mount.dig("TmpfsOptions", "Mode")).to eq(0o755)
  end
end
