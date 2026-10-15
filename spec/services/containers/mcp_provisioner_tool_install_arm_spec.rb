# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::McpProvisioner do # @spec TOOL-SIDECAR-002 # @spec TOOL-SIDECAR-005 # @spec TOOL-SIDECAR-006
  let(:provisioner) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  before do
    allow(Containers::Provision).to receive(:ensure_network!)
    allow(Docker::Image).to receive(:create)
    FeatureFlags.flipper.features.each(&:remove)
    FeatureFlags.enable!(:marketplace_tool_sidecars, project: project)
    ensure_owner_user_setting_for_tool_images!(project)
  end

  def create_run_with_tool_snapshot(snapshot)
    agent_run = create(:agent_run, project: project, issue: issue)
    AgentRun.where(id: agent_run.id).update_all(tool_sidecar_snapshot: snapshot)
    agent_run.reload
  end

  # The image gate evaluates `UserSetting.allowed_service_images` for the
  # project's account admins/owners (mirroring `ServiceContainer#image_in_allowlist`).
  # The factory user is the project's `created_by` (and therefore the account
  # owner); seed a UserSetting with the canonical default allowlist so the
  # "postgres:25"-family tools (and the `acme/*` custom tools marked as
  # explicitly allowlisted via their test setup) pass the gate.
  def ensure_owner_user_setting_for_tool_images!(target_project)
    owner = target_project.created_by || target_project.account.users.first
    if owner && !AccountMembership.where(user_id: owner.id, account_id: target_project.account.id, role: [ :admin, :owner ]).exists?
      owner.add_role(:owner, target_project.account)
    end
    existing = owner&.user_setting
    return if existing && Array(existing.allowed_service_images).include?("postgres:16")

    create(:user_setting,
      user: owner,
      allowed_service_images: [
        "postgres:16",
        "redis:7-alpine",
        "selenium/standalone-chromium:latest",
        "acme/custom-tool:latest",
        "acme/custom:1.0",
        "acme/custom:latest"
      ])
  end

  describe "#provision" do
    let(:docker_container) { instance_double(Docker::Container, id: "tool-abc123") }

    context "with a tool install_type definition (alias: net, install_type: tool)" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "code-search",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "postgres:16",
            "env" => {},
            "metadata" => { "port" => 8080 }
          }
        ])
      end

      before do
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-tool-") })
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
        allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
      end

      it "provisions a sidecar on paid_agent with capabilities dropped" do
        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "HostConfig" => hash_including(
              "CapDrop" => [ "ALL" ],
              "SecurityOpt" => [ "no-new-privileges:true" ]
            )
          )
        )
      end

      it "uses the network policy network and a paid-tool- alias" do
        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "HostConfig" => hash_including("NetworkMode" => NetworkPolicy::NETWORK_NAME),
            "NetworkingConfig" => {
              "EndpointsConfig" => {
                NetworkPolicy::NETWORK_NAME => {
                  "Aliases" => [ satisfy { |a| a.start_with?("paid-tool-code-search-run") } ]
                }
              }
            },
            "Labels" => hash_including(
              "paid.tool_sidecar" => "true",
              "paid.agent_run_id" => agent_run.id.to_s
            )
          )
        )
      end

      it "tracks the container id on tool_sidecar_container_ids" do
        provisioner.provision(agent_run)

        expect(agent_run.reload.tool_sidecar_container_ids).to eq([ "tool-abc123" ])
      end

      it "does not register the tool as an MCP url server" do
        result = provisioner.provision(agent_run)

        expect(result[:url_servers]).to eq([])
        expect(result[:stdio_servers]).to eq([])
      end

      it "does not append to mcp_sidecar_container_ids" do
        provisioner.provision(agent_run)

        expect(agent_run.reload.mcp_sidecar_container_ids).to eq([])
      end

      it "applies the postgres image-family hardening profile" do
        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "ReadonlyRootfs" => true,
            "User" => "postgres",
            "HostConfig" => hash_including(
              "CapAdd" => [ "CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID" ]
            )
          )
        )
      end

      it "applies resource limits" do
        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "HostConfig" => hash_including(
              "Memory" => Containers::McpProvisioner::RESOURCE_LIMITS[:memory],
              "PidsLimit" => Containers::McpProvisioner::RESOURCE_LIMITS[:pids_limit]
            )
          )
        )
      end

      it "waits for the TCP health probe" do
        provisioner.provision(agent_run)

        expect(Containers::TcpHealthProbe).to have_received(:open?).with(
          backend: kind_of(Containers::Backends::Base),
          container: docker_container,
          host: satisfy { |h| h.start_with?("paid-tool-code-search-run") },
          port: 8080
        )
      end

      context "when an unrecognized image is configured" do
        let(:agent_run) do
          create_run_with_tool_snapshot([
            {
              "name" => "unknown-tool",
              "transport" => "http",
              "install_type" => "tool",
              "image" => "acme/custom-tool:latest",
              "env" => {},
              "metadata" => { "port" => 9090 }
            }
          ])
        end

        it "uses the default hardening profile (writable root fs, no caps added)" do
          provisioner.provision(agent_run)

          expect(Docker::Container).to have_received(:create).with(
            hash_including(
              "ReadonlyRootfs" => false,
              "CapAdd" => [],
              "CapDrop" => [ "ALL" ],
              "SecurityOpt" => [ "no-new-privileges:true" ]
            )
          )
        end
      end
    end

    context "with a non-allowlisted image" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "unapproved",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "acme/not-on-allowlist:latest",
            "env" => {},
            "metadata" => { "port" => 9000 }
          }
        ])
      end

      before do
        allow(Docker::Container).to receive(:create)
      end

      it "fails closed without creating a container" do
        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::McpProvisioner::Error, /not in the allowed service images list/)

        expect(Docker::Container).not_to have_received(:create)
      end

      it "does not record container ids on the run" do
        provisioner.provision(agent_run) rescue nil

        expect(agent_run.reload.tool_sidecar_container_ids).to eq([])
      end

      it "does not pull the image" do
        provisioner.provision(agent_run) rescue nil

        expect(Docker::Image).not_to have_received(:create)
      end
    end

    context "with a blank image" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "missing-image",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "",
            "env" => {},
            "metadata" => { "port" => 9000 }
          }
        ])
      end

      before { allow(Docker::Container).to receive(:create) }

      it "fails closed without creating a container" do
        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::McpProvisioner::Error, /not in the allowed service images list/)

        expect(Docker::Container).not_to have_received(:create)
      end
    end

    context "with a PAID_SERVICE_HARDENING override" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "override-tool",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "acme/custom-tool:latest",
            "env" => {
              "PAID_SERVICE_HARDENING" => {
                "cap_add" => [ "NET_BIND_SERVICE" ],
                "tmpfs" => {
                  "/var/lib/custom" => { "size" => 65_536, "mode" => "0750", "uid" => 1000, "gid" => 1000 }
                }
              }
            },
            "metadata" => { "port" => 9090 }
          }
        ])
      end

      before do
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-tool-") })
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
        allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
      end

      it "applies the override tmpfs and cap_add" do
        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "HostConfig" => hash_including(
              "CapAdd" => [ "NET_BIND_SERVICE" ],
              "Tmpfs" => hash_including(
                "/var/lib/custom" => satisfy { |v| v.include?("size=65536") && v.include?("uid=1000") && v.include?("gid=1000") }
              )
            )
          )
        )
      end
    end

    context "with a PAID_SERVICE_HARDENING override that violates the rules" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "override-bad",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "postgres:16",
            "env" => {
              "PAID_SERVICE_HARDENING" => {
                "readonly_rootfs" => false
              }
            },
            "metadata" => { "port" => 5432 }
          }
        ])
      end

      before do
        allow(Docker::Container).to receive(:create)
      end

      it "fails closed when disabling readonly_rootfs for a built-in family" do
        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::McpProvisioner::Error, /readonly_rootfs cannot disable the built-in/)
      end
    end

    context "with a built-in user override" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "override-user",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "postgres:16",
            "env" => { "PAID_SERVICE_HARDENING" => { "user" => "root" } },
            "metadata" => { "port" => 5432 }
          }
        ])
      end

      before { allow(Docker::Container).to receive(:create) }

      it "fails closed when overriding the built-in runtime user" do
        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::McpProvisioner::Error, /user cannot override the built-in postgres runtime user/)

        expect(Docker::Container).not_to have_received(:create)
      end
    end

    context "with an unsupported cap_add override" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "override-bad-cap",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "acme/custom:latest",
            "env" => {
              "PAID_SERVICE_HARDENING" => {
                "cap_add" => [ "SYS_ADMIN" ]
              }
            },
            "metadata" => { "port" => 9090 }
          }
        ])
      end

      before do
        allow(Docker::Container).to receive(:create)
      end

      it "fails closed when the override requests an unsafe capability" do
        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::McpProvisioner::Error, /contains unsupported capabilities: SYS_ADMIN/)
      end
    end

    context "when a prior attempt left stale tool containers" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "stale-tool",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "postgres:16",
            "env" => {},
            "metadata" => { "port" => 8080 }
          }
        ])
      end
      let(:stale_container) { instance_double(Docker::Container, id: "tool-stale") }

      before do
        agent_run.update_columns(tool_sidecar_container_ids: [ "tool-stale" ])
        allow(Docker::Container).to receive(:get).with("tool-stale").and_return(stale_container)
        allow(stale_container).to receive_messages(stop: nil, delete: nil)
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-tool-") })
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(start: nil, json: { "State" => { "Running" => false } })
        allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
      end

      it "cleans up stale tool sidecars before provisioning" do
        provisioner.provision(agent_run)

        expect(stale_container).to have_received(:stop)
        expect(stale_container).to have_received(:delete)
        expect(agent_run.reload.tool_sidecar_container_ids).to eq([ "tool-abc123" ])
      end
    end

    context "when a container already exists from a prior attempt" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "existing-tool",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "postgres:16",
            "env" => {},
            "metadata" => { "port" => 8080 }
          }
        ])
      end
      let(:existing_container) { instance_double(Docker::Container, id: "tool-existing") }

      before do
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-tool-") })
          .and_return(existing_container)
        allow(Docker::Container).to receive(:create)
        allow(existing_container).to receive_messages(
          json: { "State" => { "Running" => true } },
          start: nil
        )
        allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
      end

      it "adopts the existing tool container" do
        provisioner.provision(agent_run)

        expect(Docker::Container).not_to have_received(:create)
        expect(agent_run.reload.tool_sidecar_container_ids).to eq([ "tool-existing" ])
      end
    end

    context "when the health probe times out" do
      let(:agent_run) do
        create_run_with_tool_snapshot([
          {
            "name" => "timeout-tool",
            "transport" => "http",
            "install_type" => "tool",
            "image" => "acme/custom:latest",
            "env" => {},
            "metadata" => { "port" => 8080 }
          }
        ])
      end

      before do
        allow(Docker::Container).to receive(:get)
          .with(satisfy { |name| name.start_with?("paid-tool-") })
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive_messages(
          json: { "State" => { "Running" => false } },
          start: nil,
          stop: nil,
          delete: nil
        )
        allow(Containers::TcpHealthProbe).to receive(:open?).and_return(false)
        stub_const("Containers::McpProvisioner::HEALTH_CHECK_TIMEOUT", 0)
      end

      it "raises an error and cleans up the partially created container" do
        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::McpProvisioner::Error, /Health check timeout for tool sidecar/)

        expect(docker_container).to have_received(:delete)
        expect(agent_run.reload.tool_sidecar_container_ids).to eq([])
      end
    end
  end

  describe "#provision with feature flag disabled" do
    let(:agent_run) do
      create_run_with_tool_snapshot([
        {
          "name" => "flag-off-tool",
          "transport" => "http",
          "install_type" => "tool",
          "image" => "postgres:16",
          "env" => {},
          "metadata" => { "port" => 8080 }
        }
      ])
    end

    before do
      FeatureFlags.disable!(:marketplace_tool_sidecars)
      allow(Docker::Container).to receive(:create)
    end

    it "creates no containers and records no tool ids" do
      result = provisioner.provision(agent_run)

      expect(result).to eq(stdio_servers: [], url_servers: [])
      expect(Docker::Container).not_to have_received(:create)
      expect(agent_run.reload.tool_sidecar_container_ids).to eq([])
    end
  end

  describe "#cleanup_tool_sidecars" do
    let(:agent_run) { create(:agent_run, project: project, issue: issue) }

    context "when no tool sidecar containers exist" do
      it "is a no-op" do
        expect { provisioner.cleanup_tool_sidecars(agent_run) }.not_to raise_error
      end
    end

    context "when tool sidecar containers exist" do
      let(:docker_container) { instance_double(Docker::Container, id: "tool-cleanup123") }

      before do
        agent_run.update_columns(tool_sidecar_container_ids: [ "tool-cleanup123" ])
        allow(Docker::Container).to receive(:get).with("tool-cleanup123").and_return(docker_container)
        allow(docker_container).to receive(:stop)
        allow(docker_container).to receive(:delete)
      end

      it "stops and removes tool sidecar containers" do
        provisioner.cleanup_tool_sidecars(agent_run)

        expect(docker_container).to have_received(:stop).with(timeout: 10)
        expect(docker_container).to have_received(:delete).with(force: true, v: true)
      end

      it "clears tool_sidecar_container_ids" do
        provisioner.cleanup_tool_sidecars(agent_run)

        expect(agent_run.reload.tool_sidecar_container_ids).to eq([])
      end
    end
  end

  describe "#cleanup" do
    let(:agent_run) { create(:agent_run, project: project, issue: issue) }
    let(:docker_container) { instance_double(Docker::Container, id: "tool-run-cleanup123") }

    before do
      agent_run.update_columns(tool_sidecar_container_ids: [ "tool-run-cleanup123" ])
      allow(Docker::Container).to receive(:get).with("tool-run-cleanup123").and_return(docker_container)
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)
    end

    it "removes tool sidecars through the normal run cleanup entrypoint" do
      provisioner.cleanup(agent_run)

      expect(docker_container).to have_received(:delete).with(force: true, v: true)
      expect(agent_run.reload.tool_sidecar_container_ids).to eq([])
    end
  end

  describe "#tool_sidecar_hostname" do
    it "generates a stable per-run paid-tool- hostname" do
      agent_run = instance_double(AgentRun, id: 42)
      hostname = provisioner.send(:tool_sidecar_hostname, agent_run, "my-tool")

      expect(hostname).to match(/\Apaid-tool-my-tool-run42\z/)
      expect(hostname.length).to be <= 63
    end

    it "sanitizes special characters" do
      agent_run = instance_double(AgentRun, id: 1)
      hostname = provisioner.send(:tool_sidecar_hostname, agent_run, "My Tool @Custom!")

      expect(hostname).to match(/\Apaid-tool-my-tool-custom-run1\z/)
    end
  end
end
