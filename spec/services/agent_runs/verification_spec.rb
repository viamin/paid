# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::Verification do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, project: project, issue: issue) }
  let(:network) { NetworkPolicy::NETWORK_NAME }
  let(:provisioner) { described_class.new(agent_run: agent_run, network: network) }
  let(:docker_container) { instance_double(Docker::Container, id: "browser-xyz") }
  let(:browser_container_name) { "#{described_class::BROWSER_CONTAINER_NAME_PREFIX}-run#{agent_run.id}" }

  before do
    allow(NetworkPolicy).to receive(:ensure_network!)
    allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
    allow(Containers.backend).to receive(:pull_image)
    allow(Docker::Container).to receive(:create)
  end

  describe "#call" do
    context "when the browser container does not exist yet" do
      before do
        allow(Docker::Container).to receive(:get)
          .with(browser_container_name)
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
      end

      it "provisions a browser container on the agent network" do
        result = provisioner.call

        expect(Containers.backend).to have_received(:pull_image).with("fromImage" => AgentRuns::Verification::BROWSER_IMAGE)
        expect_browser_container_created
        expect(result).to be_success
        expect(result.container_id).to eq("browser-xyz")
        expect(result.hostname).to eq(AgentRuns::Verification::BROWSER_HOSTNAME)
        expect(result.cdp_url).to eq(AgentRuns::Verification::CDP_URL)
      end

      it "tracks the container id on the agent run's mcp_sidecar_container_ids" do
        provisioner.call

        expect(agent_run.reload.mcp_sidecar_container_ids).to include("browser-xyz")
      end

      it "ensures the playwright-mcp MCP definition is attached to the project" do
        expect {
          provisioner.call
        }.to change {
          project.account.mcp_server_definitions.where(name: Project::PLAYWRIGHT_MCP_NAME).count
        }.by(1)

        definition = project.account.mcp_server_definitions.find_by(name: Project::PLAYWRIGHT_MCP_NAME)
        expect(project.project_mcp_servers.exists?(mcp_server_definition: definition)).to be true
      end

      it "refreshes the agent run's MCP snapshot to include playwright-mcp" do
        expect(agent_run.mcp_server_snapshot).to eq([])

        provisioner.call

        snapshot = agent_run.reload.mcp_server_snapshot
        expect(snapshot.size).to eq(1)
        expect(snapshot.first["name"]).to eq(Project::PLAYWRIGHT_MCP_NAME)
        expect(snapshot.first["env"]).to eq("CDP_URL" => Project::PLAYWRIGHT_MCP_CDP_URL)
      end

      it "preserves existing run snapshots while appending playwright-mcp" do
        original_snapshot = [
          { "name" => "existing-stdio", "command" => "npx", "args" => [ "serve" ] },
          { "name" => "marketplace-tool", "marketplace_attachment" => true, "command" => "uvx" }
        ]
        AgentRun.where(id: agent_run.id).update_all(mcp_server_snapshot: original_snapshot)
        agent_run.reload

        create(:mcp_server_definition,
          account: account,
          name: "late-added-project-server",
          transport: "stdio",
          install_type: "npx",
          command: "late-added")
        ProjectMcpServer.create!(project: project, mcp_server_definition: account.mcp_server_definitions.find_by!(name: "late-added-project-server"))

        provisioner.call

        expect(agent_run.reload.mcp_server_snapshot).to eq(
          original_snapshot + [ project.account.mcp_server_definitions.find_by!(name: Project::PLAYWRIGHT_MCP_NAME).to_snapshot ]
        )
      end

      it "materializes playwright-mcp into the existing provisioned stdio servers" do
        agent_run.update!(
          mcp_provisioned_servers: {
            "stdio_servers" => [ { "name" => "fs", "transport" => "stdio", "command" => "npx-pkg", "args" => [ "/ws" ] } ],
            "url_servers" => [ { "name" => "github", "transport" => "sse", "url" => "http://mcp/sse" } ]
          },
          mcp_sidecar_container_ids: [ "existing-sidecar" ]
        )

        provisioner.call

        provisioned = agent_run.reload.mcp_provisioned_servers
        expect(provisioned["stdio_servers"]).to contain_exactly(
          { "name" => "fs", "transport" => "stdio", "command" => "npx-pkg", "args" => [ "/ws" ] },
          playwright_stdio_server
        )
        expect(provisioned["url_servers"]).to eq([ { "name" => "github", "transport" => "sse", "url" => "http://mcp/sse" } ])
        expect(agent_run.mcp_sidecar_container_ids).to contain_exactly("existing-sidecar", "browser-xyz")
      end

      it "replaces an existing playwright-mcp stdio entry instead of duplicating it" do
        agent_run.update!(
          mcp_provisioned_servers: {
            "stdio_servers" => [
              { "name" => Project::PLAYWRIGHT_MCP_NAME, "transport" => "stdio", "command" => "stale", "args" => [ "--old" ] }
            ],
            "url_servers" => []
          }
        )

        provisioner.call

        expect(agent_run.reload.mcp_provisioned_servers["stdio_servers"]).to eq([ playwright_stdio_server ])
      end
    end

    context "when this agent run's browser container already exists" do
      let(:existing_container) { instance_double(Docker::Container, id: "browser-existing") }
      let(:existing_container_json) do
        {
          "Config" => {
            "Labels" => {
              AgentRuns::Verification::BROWSER_LABEL => "true",
              AgentRuns::Verification::AGENT_RUN_LABEL => agent_run.id.to_s
            }
          },
          "NetworkSettings" => {
            "Networks" => {
              network => { "Aliases" => [ AgentRuns::Verification::BROWSER_HOSTNAME ] }
            }
          },
          "State" => { "Running" => true }
        }
      end

      before do
        allow(Docker::Container).to receive(:get)
          .with(browser_container_name)
          .and_return(existing_container)
        allow(existing_container).to receive_messages(
          json: existing_container_json,
          start: nil
        )
      end

      it "adopts the existing container instead of creating a new one" do
        result = provisioner.call

        expect(Docker::Container).not_to have_received(:create)
        expect(existing_container).not_to have_received(:start)
        expect(result.container_id).to eq("browser-existing")
      end

      it "does not duplicate the sidecar id when already recorded" do
        agent_run.update_columns(mcp_sidecar_container_ids: [ "browser-existing" ])
        provisioner.call
        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([ "browser-existing" ])
      end

      it "untracks the browser before reprovision so retries do not delete it as stale" do
        agent_run.update_columns(mcp_sidecar_container_ids: [ "browser-existing" ])
        allow(existing_container).to receive(:stop)
        allow(existing_container).to receive(:delete)

        provisioner.call

        expect(existing_container).not_to have_received(:stop)
        expect(existing_container).not_to have_received(:delete)
      end

      it "adds the sidecar id when it was not previously tracked" do
        agent_run.update_columns(mcp_sidecar_container_ids: [])
        provisioner.call
        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([ "browser-existing" ])
      end
    end

    context "when the browser container exists but is not running" do
      let(:stopped_container) { instance_double(Docker::Container, id: "browser-stopped") }
      let(:stopped_container_json) do
        {
          "Config" => {
            "Labels" => {
              AgentRuns::Verification::BROWSER_LABEL => "true",
              AgentRuns::Verification::AGENT_RUN_LABEL => agent_run.id.to_s
            }
          },
          "NetworkSettings" => {
            "Networks" => {
              network => { "Aliases" => [ AgentRuns::Verification::BROWSER_HOSTNAME ] }
            }
          },
          "State" => { "Running" => false }
        }
      end

      before do
        allow(Docker::Container).to receive(:get)
          .with(browser_container_name)
          .and_return(stopped_container)
        allow(stopped_container).to receive_messages(
          json: stopped_container_json,
          start: nil
        )
      end

      it "starts the existing container" do
        provisioner.call

        expect(stopped_container).to have_received(:start)
      end
    end

    context "when the MCP snapshot already includes playwright-mcp" do
      let(:definition) do
        create(:mcp_server_definition,
          account: account,
          name: Project::PLAYWRIGHT_MCP_NAME,
          transport: "stdio",
          install_type: "npx",
          command: Project::PLAYWRIGHT_MCP_COMMAND,
          env: { "CDP_URL" => Project::PLAYWRIGHT_MCP_CDP_URL },
          metadata: Project::PLAYWRIGHT_MCP_METADATA)
      end

      before do
        ProjectMcpServer.create!(project: project, mcp_server_definition: definition)
        # Simulate the snapshot already containing playwright-mcp by manually
        # setting the readonly column via update_all.
        AgentRun.where(id: agent_run.id).update_all(mcp_server_snapshot: [ definition.to_snapshot ])
        agent_run.reload

        allow(Docker::Container).to receive(:get)
          .with(browser_container_name)
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
      end

      it "does not duplicate the MCP definition" do
        expect {
          provisioner.call
        }.not_to change {
          project.account.mcp_server_definitions.where(name: Project::PLAYWRIGHT_MCP_NAME).count
        }
      end

      it "replaces a stale playwright snapshot entry with the latest definition snapshot" do
        stale_snapshot = definition.to_snapshot.deep_dup.tap do |snapshot|
          snapshot["command"] = "stale-command"
          snapshot["env"] = {}
        end
        preserved_snapshot = { "name" => "existing-stdio", "command" => "npx", "args" => [ "serve" ] }
        AgentRun.where(id: agent_run.id).update_all(mcp_server_snapshot: [ preserved_snapshot, stale_snapshot ])
        agent_run.reload

        provisioner.call

        synchronized_snapshot = agent_run.reload.mcp_server_snapshot

        expect(synchronized_snapshot.first).to eq(preserved_snapshot)
        expect(synchronized_snapshot.second).to include(
          "name" => Project::PLAYWRIGHT_MCP_NAME,
          "command" => definition.command,
          "env" => definition.env,
          "install_type" => definition.install_type,
          "metadata" => definition.metadata,
          "transport" => definition.transport
        )
      end
    end

    context "when Docker returns an error" do
      before do
        allow(Docker::Container).to receive(:get)
          .with(browser_container_name)
          .and_raise(Docker::Error::DockerError, "boom")
      end

      it "wraps the error in an AgentRuns::Verification::Error" do
        expect { provisioner.call }.to raise_error(
          AgentRuns::Verification::Error, /Failed to provision verification browser container/
        )
      end
    end

    context "when pulling the browser image fails because it is missing" do
      before do
        allow(Docker::Container).to receive(:get)
          .with(browser_container_name)
          .and_raise(Docker::Error::NotFoundError)
        allow(Containers.backend).to receive(:pull_image)
          .with("fromImage" => AgentRuns::Verification::BROWSER_IMAGE)
          .and_raise(Docker::Error::NotFoundError)
      end

      it "raises a non-retryable configuration error" do
        expect { provisioner.call }.to raise_error(
          AgentRuns::Verification::Error,
          "Verification browser image not found: #{AgentRuns::Verification::BROWSER_IMAGE}"
        )
      end
    end

    context "when a stale container with the same run-specific name is on the wrong network" do
      let(:stale_container) { instance_double(Docker::Container, id: "browser-stale") }

      before do
        allow(Docker::Container).to receive(:get)
          .with(browser_container_name)
          .and_return(stale_container)
        allow(stale_container).to receive(:json).and_return(
          {
            "Config" => {
              "Labels" => {
                AgentRuns::Verification::BROWSER_LABEL => "true",
                AgentRuns::Verification::AGENT_RUN_LABEL => agent_run.id.to_s
              }
            },
            "NetworkSettings" => {
              "Networks" => {
                "some-other-network" => { "Aliases" => [ AgentRuns::Verification::BROWSER_HOSTNAME ] }
              }
            },
            "State" => { "Running" => true }
          }
        )
        allow(stale_container).to receive(:stop)
        allow(stale_container).to receive(:delete)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
      end

      it "replaces the stale container so the browser alias resolves on the current network" do
        result = provisioner.call

        expect(stale_container).to have_received(:stop).with(timeout: 10)
        expect(stale_container).to have_received(:delete).with(force: true, v: true)
        expect(Docker::Container).to have_received(:create).with(hash_including("name" => browser_container_name))
        expect(result.container_id).to eq("browser-xyz")
      end
    end
  end

  def playwright_stdio_server
    {
      "name" => Project::PLAYWRIGHT_MCP_NAME,
      "transport" => "stdio",
      "command" => Project::PLAYWRIGHT_MCP_COMMAND,
      "args" => [],
      "env" => { "CDP_URL" => Project::PLAYWRIGHT_MCP_CDP_URL }
    }
  end

  def expect_browser_container_created
    expect(Docker::Container).to have_received(:create).with(
      hash_including(
        "Image" => AgentRuns::Verification::BROWSER_IMAGE,
        "name" => browser_container_name,
        "NetworkingConfig" => {
          "EndpointsConfig" => {
            network => { "Aliases" => [ AgentRuns::Verification::BROWSER_HOSTNAME ] }
          }
        },
        "Labels" => hash_including(
          AgentRuns::Verification::BROWSER_LABEL => "true",
          "paid.agent_run_id" => agent_run.id.to_s
        )
      )
    )
  end
end
