# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ServiceProvisioner do
  let(:provisioner) { described_class.new }

  describe "#provision" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:agent_run) { create(:agent_run, project: project, issue: issue) }

    before do
      allow(NetworkPolicy).to receive(:ensure_network!)
    end

    context "when project has no service containers" do
      it "returns empty hash" do
        result = provisioner.provision(agent_run)
        expect(result).to eq({})
      end

      it "does not update agent run" do
        provisioner.provision(agent_run)
        agent_run.reload
        expect(agent_run.service_container_ids).to eq([])
        expect(agent_run.service_environment).to eq({})
      end
    end

    context "when project has service containers" do
      let(:service_container) do
        create(:service_container,
          image: "postgres:16",
          name: "test-postgres",
          port: 5432,
          env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" })
      end

      before do
        create(:project_service_container, project: project, service_container: service_container)
      end

      it "starts stopped containers" do
        docker_container = instance_double(Docker::Container, id: "abc123")
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive(:start)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)
        allow(ServiceContainerMetricsCollectionJob).to receive(:perform_later)

        result = provisioner.provision(agent_run)

        expect(result).to include("DATABASE_URL")
        expect(result["DATABASE_URL"]).to eq("postgres://agent:agent@test-postgres:5432/agent_test")
        expect(agent_run.reload.service_container_ids).to eq([ service_container.id ])
        expect(ServiceContainerMetricsCollectionJob).to have_received(:perform_later).with(service_container.id)
      end

      it "reuses running containers when Docker container is alive" do
        service_container.update!(status: "running", docker_container_id: "alive123")
        alive_container = instance_double(Docker::Container,
          info: { "State" => { "Running" => true } })
        allow(Docker::Container).to receive(:get).with("alive123").and_return(alive_container)
        allow(Docker::Container).to receive(:create).and_call_original

        result = provisioner.provision(agent_run)

        expect(result).to include("DATABASE_URL")
        expect(Docker::Container).not_to have_received(:create)
      end

      it "re-provisions when Docker container is dead" do
        service_container.update!(status: "running", docker_container_id: "dead123")
        allow(Docker::Container).to receive(:get).with("dead123")
          .and_raise(Docker::Error::NotFoundError)

        new_container = instance_double(Docker::Container, id: "new456")
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(new_container)
        allow(new_container).to receive(:start)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)

        result = provisioner.provision(agent_run)

        expect(result).to include("DATABASE_URL")
        expect(service_container.reload.docker_container_id).to eq("new456")
      end
    end

    context "when container start fails" do
      let(:service_container) do
        create(:service_container,
          image: "postgres:16",
          name: "fail-postgres",
          port: 5432,
          env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" })
      end

      before do
        create(:project_service_container, project: project, service_container: service_container)
      end

      it "cleans up the Docker container on failure" do
        docker_container = instance_double(Docker::Container, id: "leak123")
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive(:start)
        allow(Docker::Container).to receive(:get).with("leak123").and_return(docker_container)
        allow(docker_container).to receive(:stop)
        allow(docker_container).to receive(:delete)

        # Simulate health check timeout by raising directly from wait_for_health!
        allow(provisioner).to receive(:wait_for_health!).and_raise(
          Containers::ServiceProvisioner::Error,
          "Health check timeout for fail-postgres:5432"
        )

        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::ServiceProvisioner::Error, /Failed to start/)

        expect(docker_container).to have_received(:stop).with(timeout: 10)
        expect(docker_container).to have_received(:delete).with(force: true)
        expect(service_container.reload.status).to eq("error")
        expect(service_container.docker_container_id).to be_nil
      end
    end

    context "when Docker container name conflicts" do
      let(:service_container) do
        create(:service_container,
          image: "postgres:16",
          name: "conflict-postgres",
          port: 5432,
          env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" })
      end
      let(:managed_labels) do
        { "paid.service_container" => "true", "paid.service_container_id" => service_container.id.to_s }
      end
      let(:stale_json) do
        { "Config" => { "Labels" => managed_labels }, "State" => { "Running" => false } }
      end

      before do
        create(:project_service_container, project: project, service_container: service_container)
      end


      it "removes stale stopped container and retries" do
        stale = instance_double(Docker::Container, id: "stale789")
        new_container = instance_double(Docker::Container, id: "new789")

        allow(Docker::Image).to receive(:create)
        call_count = 0
        allow(Docker::Container).to receive(:create) do
          call_count += 1
          raise Docker::Error::ConflictError, "Conflict. The container name is already in use" if call_count == 1
          new_container
        end
        allow(Docker::Container).to receive(:get).with("conflict-postgres").and_return(stale)
        allow(stale).to receive(:json).and_return(stale_json)
        allow(stale).to receive(:stop)
        allow(stale).to receive(:delete)
        allow(new_container).to receive(:start)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)

        result = provisioner.provision(agent_run)

        expect(stale).to have_received(:delete).with(force: true)
        expect(result).to include("DATABASE_URL")
      end

      it "adopts a running container instead of deleting it" do
        existing = instance_double(Docker::Container, id: "running789")
        running_json = { "Config" => { "Labels" => managed_labels }, "State" => { "Running" => true } }

        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create)
          .and_raise(Docker::Error::ConflictError, "Conflict. The container name is already in use")
        allow(Docker::Container).to receive(:get).with("conflict-postgres").and_return(existing)
        allow(existing).to receive_messages(json: running_json, stop: nil, delete: nil)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)

        result = provisioner.provision(agent_run)

        expect(existing).not_to have_received(:stop)
        expect(existing).not_to have_received(:delete)
        expect(service_container.reload.docker_container_id).to eq("running789")
        expect(result).to include("DATABASE_URL")
      end

      it "raises when stale container is not managed by Paid" do
        stale = instance_double(Docker::Container, id: "foreign789")

        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create)
          .and_raise(Docker::Error::ConflictError, "Conflict. The container name is already in use")
        allow(Docker::Container).to receive(:get).with("conflict-postgres").and_return(stale)
        allow(stale).to receive(:json).and_return({ "Config" => { "Labels" => {} } })

        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::ServiceProvisioner::Error, /not managed by Paid/)
      end

      it "raises when container belongs to a different service_container" do
        stale = instance_double(Docker::Container, id: "wrong789")
        wrong_labels = { "paid.service_container" => "true", "paid.service_container_id" => "9999" }

        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create)
          .and_raise(Docker::Error::ConflictError, "Conflict. The container name is already in use")
        allow(Docker::Container).to receive(:get).with("conflict-postgres").and_return(stale)
        allow(stale).to receive(:json).and_return({ "Config" => { "Labels" => wrong_labels } })

        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::ServiceProvisioner::Error, /belongs to service_container 9999/)
      end
    end

    context "with environment variable generation" do
      before do
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(
          instance_double(Docker::Container, id: "test123").tap { |c| allow(c).to receive(:start) }
        )
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)
      end

      it "generates DATABASE_URL for postgres images" do
        sc = create(:service_container, image: "postgres:16", name: "pg", port: 5432,
          env: { "POSTGRES_USER" => "u", "POSTGRES_PASSWORD" => "p", "POSTGRES_DB" => "d" })
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expect(result["DATABASE_URL"]).to eq("postgres://u:p@pg:5432/d")
      end

      it "injects default postgres env and healthcheck when env is empty" do
        sc = create(:service_container, image: "postgres:16", name: "pg-defaults", port: 5432, env: {})
        create(:project_service_container, project: project, service_container: sc)

        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "Env" => include(
              "POSTGRES_USER=agent",
              "POSTGRES_PASSWORD=agent",
              "POSTGRES_DB=agent_test"
            ),
            "Healthcheck" => hash_including(
              "Test" => [ "CMD", "pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", "agent", "-d", "agent_test" ]
            )
          )
        )
      end

      it "generates REDIS_URL for redis images" do
        sc = create(:service_container, :redis, name: "redis-test", port: 6379)
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expect(result["REDIS_URL"]).to eq("redis://redis-test:6379")
      end

      it "generates SELENIUM_URL for selenium images" do
        sc = create(:service_container, :selenium, name: "selenium-test", port: 4444)
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expect(result["SELENIUM_URL"]).to eq("http://selenium-test:4444")
      end

      it "generates generic vars for unknown images" do
        admin = create(:user, :admin)
        create(:user_setting, user: admin, allowed_service_images: [ "custom:1.0" ])
        sc = create(:service_container, image: "custom:1.0", name: "my-svc", port: 8080)
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expect(result["SERVICE_MY_SVC_HOST"]).to eq("my-svc")
        expect(result["SERVICE_MY_SVC_PORT"]).to eq("8080")
      end
    end
  end

  describe "resource limits" do
    it "applies postgres resource limits to postgres images" do
      limits = provisioner.send(:resource_limits_for, "postgres:16")
      expect(limits[:memory]).to eq(2 * 1024 * 1024 * 1024)
      expect(limits[:cpu_quota]).to eq(100_000)
      expect(limits[:pids_limit]).to eq(200)
    end

    it "applies redis resource limits to redis images" do
      limits = provisioner.send(:resource_limits_for, "redis:7")
      expect(limits[:memory]).to eq(1 * 1024 * 1024 * 1024)
      expect(limits[:cpu_quota]).to eq(100_000)
      expect(limits[:pids_limit]).to eq(100)
    end

    it "applies selenium resource limits to selenium images" do
      limits = provisioner.send(:resource_limits_for, "selenium/standalone-chrome:latest")
      expect(limits[:memory]).to eq(2 * 1024 * 1024 * 1024)
      expect(limits[:cpu_quota]).to eq(200_000)
      expect(limits[:pids_limit]).to eq(300)
    end

    it "applies default resource limits to unknown images" do
      limits = provisioner.send(:resource_limits_for, "custom:1.0")
      expect(limits[:memory]).to eq(1 * 1024 * 1024 * 1024)
      expect(limits[:cpu_quota]).to eq(100_000)
      expect(limits[:pids_limit]).to eq(200)
    end
  end

  describe "Docker container creation with resource limits" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:agent_run) { create(:agent_run, project: project, issue: issue) }
    let(:service_container) do
      create(:service_container,
        image: "postgres:16",
        name: "limits-postgres",
        port: 5432,
        env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" })
    end

    before do
      create(:project_service_container, project: project, service_container: service_container)
      allow(NetworkPolicy).to receive(:ensure_network!)
    end

    it "passes resource limits to Docker::Container.create" do
      docker_container = instance_double(Docker::Container, id: "abc123")
      allow(Docker::Image).to receive(:create)
      allow(Docker::Container).to receive(:create).and_return(docker_container)
      allow(docker_container).to receive(:start)
      allow(Docker::Container).to receive(:get).with("abc123")
        .and_raise(Docker::Error::DockerError)
      allow(provisioner).to receive(:tcp_port_open?).and_return(true)

      provisioner.provision(agent_run)

      expect(Docker::Container).to have_received(:create).with(
        hash_including(
          "HostConfig" => hash_including(
            "Memory" => 2 * 1024 * 1024 * 1024,
            "MemorySwap" => 2 * 1024 * 1024 * 1024,
            "CpuPeriod" => 100_000,
            "CpuQuota" => 100_000,
            "PidsLimit" => 200
          )
        )
      )
    end
  end

  describe "Docker HEALTHCHECK-aware health monitoring" do
    it "returns true when Docker HEALTHCHECK reports healthy" do
      sc = create(:service_container, status: "running", docker_container_id: "healthy123")
      container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get).with("healthy123").and_return(container)
      allow(container).to receive(:json).and_return({
        "State" => { "Running" => true, "Health" => { "Status" => "healthy" } }
      })

      result = provisioner.send(:docker_healthcheck_status, sc)
      expect(result).to be true
    end

    it "returns false when Docker HEALTHCHECK reports unhealthy" do
      sc = create(:service_container, status: "running", docker_container_id: "unhealthy123")
      container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get).with("unhealthy123").and_return(container)
      allow(container).to receive(:json).and_return({
        "State" => { "Running" => true, "Health" => { "Status" => "unhealthy" } }
      })

      result = provisioner.send(:docker_healthcheck_status, sc)
      expect(result).to be false
    end

    it "returns nil when no HEALTHCHECK is configured" do
      sc = create(:service_container, status: "running", docker_container_id: "nohc123")
      container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get).with("nohc123").and_return(container)
      allow(container).to receive(:json).and_return({
        "State" => { "Running" => true }
      })

      result = provisioner.send(:docker_healthcheck_status, sc)
      expect(result).to be_nil
    end

    it "returns nil when docker_container_id is blank" do
      sc = create(:service_container, status: "stopped", docker_container_id: nil)

      result = provisioner.send(:docker_healthcheck_status, sc)
      expect(result).to be_nil
    end
  end

  describe "#cleanup" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:service_container) { create(:service_container, :running) }

    before do
      create(:project_service_container, project: project, service_container: service_container)
    end

    it "stops containers with no active runs" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ])

      docker_container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get)
        .with(service_container.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      provisioner.cleanup(agent_run)

      expect(service_container.reload.status).to eq("stopped")
      expect(agent_run.reload.service_container_ids).to eq([])
    end

    it "leaves containers running when other runs still need them" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ])
      create(:agent_run, :running, project: project, issue: issue,
        service_container_ids: [ service_container.id ])

      provisioner.cleanup(agent_run)

      expect(service_container.reload.status).to eq("running")
    end

    it "handles empty service_container_ids gracefully" do
      agent_run = create(:agent_run, project: project, issue: issue,
        service_container_ids: [])

      expect { provisioner.cleanup(agent_run) }.not_to raise_error
    end
  end
end
