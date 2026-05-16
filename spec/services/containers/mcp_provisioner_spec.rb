# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::McpProvisioner do
  let(:provisioner) { described_class.new }

  describe "#provision" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }

    # Helper to create an agent_run with a specific mcp_server_snapshot.
    # attr_readonly prevents update_columns, so we set snapshot before creation
    # by stubbing the project's MCP definitions.
    def create_run_with_snapshot(snapshot)
      definitions = snapshot.map do |defn|
        build(:mcp_server_definition,
          account: project.account,
          name: defn["name"],
          transport: defn["transport"],
          install_type: defn["install_type"],
          command: defn["command"],
          args: defn.fetch("args", []),
          url: defn["url"],
          image: defn["image"],
          env: defn.fetch("env", {}),
          metadata: defn.fetch("metadata", {}),
          enabled: true)
      end

      relation = McpServerDefinition.none
      allow(relation).to receive_messages(enabled: relation, order: definitions)
      allow(project).to receive(:mcp_server_definitions).and_return(relation)

      create(:agent_run, project: project, issue: issue)
    end

    context "when mcp_server_snapshot is empty" do
      let(:agent_run) { create(:agent_run, project: project, issue: issue) }

      it "returns empty server lists" do
        result = provisioner.provision(agent_run)

        expect(result).to eq(stdio_servers: [], url_servers: [])
      end

      it "does not update mcp_sidecar_container_ids" do
        provisioner.provision(agent_run)
        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([])
      end

      it "does not update mcp_provisioned_servers" do
        provisioner.provision(agent_run)
        expect(agent_run.reload.mcp_provisioned_servers).to eq({})
      end
    end

    context "with npx definitions" do
      let(:agent_run) do
        create_run_with_snapshot([
          {
            "name" => "fs-server",
            "transport" => "stdio",
            "install_type" => "npx",
            "command" => "@modelcontextprotocol/server-filesystem",
            "args" => [ "/workspace" ],
            "env" => { "KEY" => "value" }
          }
        ])
      end

      it "materializes npx definitions as stdio server specs" do
        result = provisioner.provision(agent_run)

        expect(result[:stdio_servers]).to eq([
          {
            "name" => "fs-server",
            "transport" => "stdio",
            "command" => "@modelcontextprotocol/server-filesystem",
            "args" => [ "/workspace" ],
            "env" => { "KEY" => "value" }
          }
        ])
        expect(result[:url_servers]).to eq([])
      end

      it "does not create sidecar containers" do
        provisioner.provision(agent_run)
        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([])
      end

      it "persists materialized server specs on the agent run" do
        provisioner.provision(agent_run)

        provisioned = agent_run.reload.mcp_provisioned_servers
        expect(provisioned["stdio_servers"].size).to eq(1)
        expect(provisioned["stdio_servers"].first["name"]).to eq("fs-server")
        expect(provisioned["url_servers"]).to eq([])
      end
    end

    context "with docker_image definitions" do
      let(:docker_container) { instance_double(Docker::Container, id: "mcp-abc123") }
      let(:agent_run) do
        create_run_with_snapshot([
          {
            "name" => "pg-mcp",
            "transport" => "sse",
            "install_type" => "docker_image",
            "image" => "mcp/postgres:latest",
            "env" => { "PG_HOST" => "db" },
            "metadata" => { "port" => 8080 }
          }
        ])
      end

      before do
        allow(NetworkPolicy).to receive(:ensure_network!)
        allow(Docker::Image).to receive(:create)
        # adopt_or_create_sidecar tries get first; raise NotFound to fall through to create
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-mcp-") })
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
        allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
      end

      it "provisions a sidecar container and returns url server spec" do
        result = provisioner.provision(agent_run)

        expect(result[:url_servers].size).to eq(1)
        server = result[:url_servers].first
        expect(server["name"]).to eq("pg-mcp")
        expect(server["transport"]).to eq("sse")
        expect(server["url"]).to match(%r{^http://paid-mcp-.*:8080/sse$})
        expect(server).not_to have_key("env")
      end

      it "tracks sidecar container IDs on the agent run" do
        provisioner.provision(agent_run)

        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([ "mcp-abc123" ])
      end

      it "pulls the Docker image" do
        provisioner.provision(agent_run)

        expect(Docker::Image).to have_received(:create).with("fromImage" => "mcp/postgres:latest")
      end

      it "creates a container with correct labels" do
        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "Labels" => hash_including(
              "paid.mcp_sidecar" => "true",
              "paid.agent_run_id" => agent_run.id.to_s
            )
          )
        )
      end

      it "uses default port when metadata.port is not set" do
        run = create_run_with_snapshot([
          {
            "name" => "generic-mcp",
            "transport" => "sse",
            "install_type" => "docker_image",
            "image" => "mcp/generic:latest"
          }
        ])

        result = provisioner.provision(run)

        server = result[:url_servers].first
        expect(server["url"]).to match(/:3000\/sse$/)
      end

      it "persists materialized server specs on the agent run" do
        provisioner.provision(agent_run)

        provisioned = agent_run.reload.mcp_provisioned_servers
        expect(provisioned["url_servers"].size).to eq(1)
        expect(provisioned["url_servers"].first["name"]).to eq("pg-mcp")
        expect(provisioned["stdio_servers"]).to eq([])
      end

      it "rejects docker_image definitions with non-sse transport" do
        run = create_run_with_snapshot([
          {
            "name" => "stdio-docker",
            "transport" => "stdio",
            "install_type" => "docker_image",
            "image" => "mcp/postgres:latest"
          }
        ])

        expect { provisioner.provision(run) }.to raise_error(
          Containers::McpProvisioner::Error, /requires transport "sse"/
        )
      end

      it "rejects invalid port values" do
        run = create_run_with_snapshot([
          {
            "name" => "bad-port",
            "transport" => "sse",
            "install_type" => "docker_image",
            "image" => "mcp/postgres:latest",
            "metadata" => { "port" => 0 }
          }
        ])

        expect { provisioner.provision(run) }.to raise_error(
          Containers::McpProvisioner::Error, /Invalid port 0/
        )
      end

      it "rejects out-of-range port values" do
        run = create_run_with_snapshot([
          {
            "name" => "big-port",
            "transport" => "sse",
            "install_type" => "docker_image",
            "image" => "mcp/postgres:latest",
            "metadata" => { "port" => 70_000 }
          }
        ])

        expect { provisioner.provision(run) }.to raise_error(
          Containers::McpProvisioner::Error, /Invalid port 70000/
        )
      end

      context "when a prior attempt left stale containers" do
        let(:stale_container) { instance_double(Docker::Container, id: "stale-abc") }

        before do
          agent_run.update_columns(mcp_sidecar_container_ids: [ "stale-abc" ])
          allow(Docker::Container).to receive(:get).with("stale-abc").and_return(stale_container)
          allow(stale_container).to receive(:stop)
          allow(stale_container).to receive(:delete)
        end

        it "cleans up stale containers before provisioning" do
          provisioner.provision(agent_run)

          expect(stale_container).to have_received(:stop)
          expect(stale_container).to have_received(:delete)
        end
      end

      context "when a container already exists from a prior attempt" do
        let(:existing_container) { instance_double(Docker::Container, id: "mcp-existing") }

        before do
          # adopt_or_create_sidecar tries Docker::Container.get first
          allow(Docker::Container).to receive(:get)
            .with(satisfy { |name| name.start_with?("paid-mcp-") })
            .and_return(existing_container)
          allow(existing_container).to receive_messages(
            json: { "State" => { "Running" => true } },
            start: nil
          )
        end

        it "adopts the existing container without creating a new one" do
          provisioner.provision(agent_run)

          expect(Docker::Container).not_to have_received(:create)
          expect(existing_container).not_to have_received(:start)
        end
      end

      context "with a remote backend" do
        let(:backend) { Containers::Backends::LocalDocker.new }

        before do
          allow(backend).to receive(:remote?).and_return(true)
          allow(Containers).to receive(:backend).and_return(backend)
        end

        it "probes health from inside the sidecar container" do
          provisioner.provision(agent_run)

          expect(Containers::TcpHealthProbe).to have_received(:open?).with(
            backend: backend,
            container: docker_container,
            host: a_string_matching(/\Apaid-mcp-/),
            port: 8080
          )
        end
      end
    end

    context "with mixed npx and docker_image definitions" do
      let(:docker_container) { instance_double(Docker::Container, id: "mcp-mixed123") }
      let(:agent_run) do
        create_run_with_snapshot([
          {
            "name" => "fs-server",
            "transport" => "stdio",
            "install_type" => "npx",
            "command" => "@modelcontextprotocol/server-filesystem",
            "args" => [ "/workspace" ]
          },
          {
            "name" => "pg-mcp",
            "transport" => "sse",
            "install_type" => "docker_image",
            "image" => "mcp/postgres:latest",
            "metadata" => { "port" => 8080 }
          }
        ])
      end

      before do
        allow(NetworkPolicy).to receive(:ensure_network!)
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-mcp-") })
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
        allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
      end

      it "provisions both types" do
        result = provisioner.provision(agent_run)

        expect(result[:stdio_servers].size).to eq(1)
        expect(result[:url_servers].size).to eq(1)
        expect(result[:stdio_servers].first["name"]).to eq("fs-server")
        expect(result[:url_servers].first["name"]).to eq("pg-mcp")
      end
    end

    context "when docker sidecar fails to start" do
      let(:docker_container) { instance_double(Docker::Container, id: "mcp-fail123") }
      let(:agent_run) do
        create_run_with_snapshot([
          {
            "name" => "broken-mcp",
            "transport" => "sse",
            "install_type" => "docker_image",
            "image" => "mcp/broken:latest",
            "metadata" => { "port" => 3000 }
          }
        ])
      end

      before do
        allow(NetworkPolicy).to receive(:ensure_network!)
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-mcp-") })
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(
          json: { "State" => { "Running" => false } },
          stop: nil,
          delete: nil
        )
        allow(docker_container).to receive(:start).and_raise(Docker::Error::ServerError, "container start failed")
      end

      it "raises an Error and cleans up" do
        expect { provisioner.provision(agent_run) }.to raise_error(Containers::McpProvisioner::Error, /Failed to start MCP sidecar/)
      end
    end
  end

  describe "#cleanup" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:agent_run) { create(:agent_run, project: project, issue: issue) }

    context "when no sidecar containers exist" do
      it "is a no-op" do
        expect { provisioner.cleanup(agent_run) }.not_to raise_error
      end
    end

    context "when sidecar containers exist" do
      let(:docker_container) { instance_double(Docker::Container, id: "mcp-cleanup123") }

      before do
        agent_run.update_columns(mcp_sidecar_container_ids: [ "mcp-cleanup123" ])
        allow(Docker::Container).to receive(:get).with("mcp-cleanup123").and_return(docker_container)
        allow(docker_container).to receive(:stop)
        allow(docker_container).to receive(:delete)
      end

      it "stops and removes sidecar containers" do
        provisioner.cleanup(agent_run)

        expect(docker_container).to have_received(:stop).with(timeout: 10)
        expect(docker_container).to have_received(:delete).with(force: true, v: true)
      end

      it "clears mcp_sidecar_container_ids" do
        provisioner.cleanup(agent_run)

        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([])
      end
    end

    context "when container is already gone" do
      before do
        agent_run.update_columns(mcp_sidecar_container_ids: [ "mcp-gone123" ])
        allow(Docker::Container).to receive(:get).with("mcp-gone123").and_raise(Docker::Error::NotFoundError)
      end

      it "clears mcp_sidecar_container_ids without error" do
        expect { provisioner.cleanup(agent_run) }.not_to raise_error
        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([])
      end
    end
  end

  describe "#sidecar_hostname" do
    it "generates a valid Docker hostname" do
      agent_run = instance_double(AgentRun, id: 42)
      hostname = provisioner.send(:sidecar_hostname, agent_run, "my-mcp-server")

      expect(hostname).to match(/\Apaid-mcp-my-mcp-server-run42\z/)
      expect(hostname.length).to be <= 63
    end

    it "sanitizes special characters" do
      agent_run = instance_double(AgentRun, id: 1)
      hostname = provisioner.send(:sidecar_hostname, agent_run, "My MCP Server!")

      expect(hostname).to match(/\Apaid-mcp-my-mcp-server-run1\z/)
    end
  end
end
