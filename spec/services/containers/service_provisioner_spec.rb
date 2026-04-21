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

      it "starts stopped containers with per-run database and enqueues metrics collection" do
        docker_container = instance_double(Docker::Container, id: "abc123")
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive(:start)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)

        # Stub per-run database creation
        allow(Docker::Container).to receive(:get).with("abc123").and_return(docker_container)
        allow(docker_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])

        result = provisioner.provision(agent_run)

        expected_db = provisioner.send(:per_run_db_name, agent_run)
        expect(result).to include("DATABASE_URL")
        expect(result["DATABASE_URL"]).to eq("postgres://agent:agent@test-postgres:5432/#{expected_db}")
        expect(agent_run.reload.service_container_ids).to eq([ service_container.id ])
        expect(ServiceContainerMetricsCollectionJob).to have_been_enqueued.with(service_container.id)
      end

      it "reuses running containers when Docker container is alive" do
        service_container.update!(status: "running", docker_container_id: "alive123")
        alive_container = instance_double(Docker::Container,
          id: "alive123",
          info: {
            "State" => { "Running" => true },
            "NetworkSettings" => {
              "Networks" => { NetworkPolicy::NETWORK_NAME => { "Aliases" => [ "test-postgres" ] } }
            }
          })
        allow(Docker::Container).to receive(:get).with("alive123").and_return(alive_container)
        allow(alive_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])
        allow(Docker::Container).to receive(:create).and_call_original

        result = provisioner.provision(agent_run)

        expect(result).to include("DATABASE_URL")
        expect(Docker::Container).not_to have_received(:create)
      end

      it "connects reused running containers to the requested network with the service alias" do
        service_container.update!(status: "running", docker_container_id: "alive123")
        alive_container = instance_double(Docker::Container,
          id: "alive123",
          info: {
            "State" => { "Running" => true },
            "NetworkSettings" => {
              "Networks" => { NetworkPolicy::NETWORK_NAME => { "Aliases" => [ "test-postgres" ] } }
            }
          })
        network = instance_double(Docker::Network)

        allow(Docker::Container).to receive(:get).with("alive123").and_return(alive_container)
        allow(Docker::Network).to receive(:get).with(NetworkPolicy::INFRA_NETWORK_NAME).and_return(network)
        allow(network).to receive(:connect)
        allow(alive_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])

        provisioner.provision(agent_run, network: NetworkPolicy::INFRA_NETWORK_NAME)

        expect(network).to have_received(:connect).with(
          "alive123",
          {},
          "EndpointConfig" => { "Aliases" => [ "test-postgres" ] }
        )
      end

      it "reconnects reused containers when the requested network is missing the service alias" do
        service_container.update!(status: "running", docker_container_id: "alive123")
        alive_container = instance_double(Docker::Container,
          id: "alive123",
          info: {
            "State" => { "Running" => true },
            "NetworkSettings" => { "Networks" => { NetworkPolicy::NETWORK_NAME => { "Aliases" => [] } } }
          })
        network = instance_double(Docker::Network)

        allow(Docker::Container).to receive(:get).with("alive123").and_return(alive_container)
        allow(Docker::Network).to receive(:get).with(NetworkPolicy::NETWORK_NAME).and_return(network)
        allow(network).to receive_messages(disconnect: nil, connect: nil)
        allow(alive_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])

        provisioner.provision(agent_run)

        expect(network).to have_received(:disconnect).with("alive123")
        expect(network).to have_received(:connect).with(
          "alive123",
          {},
          "EndpointConfig" => { "Aliases" => [ "test-postgres" ] }
        )
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

        # Stub per-run database creation
        allow(Docker::Container).to receive(:get).with("new456").and_return(new_container)
        allow(new_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])

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
        expect(docker_container).to have_received(:delete).with(force: true, v: true)
        expect(service_container.reload.status).to eq("error")
        expect(service_container.docker_container_id).to be_nil
      end

      it "still deletes the container when stop raises ClientError during cleanup" do
        docker_container = instance_double(Docker::Container, id: "leak456")
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(docker_container).to receive(:start)
        allow(Docker::Container).to receive(:get).with("leak456").and_return(docker_container)
        allow(docker_container).to receive(:stop)
          .and_raise(Docker::Error::ClientError, "container already stopped")
        allow(docker_container).to receive(:delete)

        allow(provisioner).to receive(:wait_for_health!).and_raise(
          Containers::ServiceProvisioner::Error,
          "Health check timeout for fail-postgres:5432"
        )

        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::ServiceProvisioner::Error, /Failed to start/)

        expect(docker_container).to have_received(:delete).with(force: true, v: true)
      end
    end

    context "when per-run database creation fails" do
      let(:service_container) do
        create(:service_container,
          image: "postgres:16",
          name: "db-fail-postgres",
          port: 5432,
          status: "running",
          docker_container_id: "shared123",
          env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" })
      end

      before do
        create(:project_service_container, project: project, service_container: service_container)
      end

      it "leaves the shared container record intact" do
        docker_container = instance_double(Docker::Container,
          id: "shared123",
          info: {
            "State" => { "Running" => true },
            "NetworkSettings" => {
              "Networks" => { NetworkPolicy::NETWORK_NAME => { "Aliases" => [ "db-fail-postgres" ] } }
            }
          })
        allow(Docker::Container).to receive(:get).with("shared123").and_return(docker_container)
        allow(docker_container).to receive(:exec)
          .and_return([ [], [ "psql: connection refused" ], 2 ])

        expect { provisioner.provision(agent_run) }
          .to raise_error(Containers::ServiceProvisioner::DatabaseError, /Failed to check/)

        expect(service_container.reload.status).to eq("running")
        expect(service_container.docker_container_id).to eq("shared123")
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
      let(:running_json) do
        { "Config" => { "Labels" => managed_labels }, "State" => { "Running" => true } }
      end
      let(:running_container) do
        instance_double(Docker::Container,
          id: "running789",
          info: {
            "State" => { "Running" => true },
            "NetworkSettings" => {
              "Networks" => { NetworkPolicy::NETWORK_NAME => { "Aliases" => [ "conflict-postgres" ] } }
            }
          })
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

        # Stub per-run database creation
        allow(Docker::Container).to receive(:get).with("new789").and_return(new_container)
        allow(new_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])

        result = provisioner.provision(agent_run)

        expect(stale).to have_received(:delete).with(force: true, v: true)
        expect(result).to include("DATABASE_URL")
      end

      it "adopts a running container instead of deleting it" do
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create)
          .and_raise(Docker::Error::ConflictError, "Conflict. The container name is already in use")
        allow(Docker::Container).to receive(:get).with("conflict-postgres").and_return(running_container)
        allow(running_container).to receive_messages(json: running_json, stop: nil, delete: nil)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)

        # Stub per-run database creation
        allow(Docker::Container).to receive(:get).with("running789").and_return(running_container)
        allow(running_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])

        result = provisioner.provision(agent_run)

        expect(running_container).not_to have_received(:stop)
        expect(running_container).not_to have_received(:delete)
        expect(service_container.reload.docker_container_id).to eq("running789")
        expect(result).to include("DATABASE_URL")
      end

      it "connects adopted running containers to the requested network with the service alias" do
        network = instance_double(Docker::Network)

        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create)
          .and_raise(Docker::Error::ConflictError, "Conflict. The container name is already in use")
        allow(Docker::Container).to receive(:get).with("conflict-postgres").and_return(running_container)
        allow(Docker::Container).to receive(:get).with("running789").and_return(running_container)
        allow(Docker::Network).to receive(:get).with(NetworkPolicy::INFRA_NETWORK_NAME).and_return(network)
        allow(network).to receive(:connect)
        allow(running_container).to receive_messages(json: running_json, stop: nil, delete: nil)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)
        allow(running_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])

        provisioner.provision(agent_run, network: NetworkPolicy::INFRA_NETWORK_NAME)

        expect(network).to have_received(:connect).with(
          "running789",
          {},
          "EndpointConfig" => { "Aliases" => [ "conflict-postgres" ] }
        )
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
      let(:docker_container) do
        instance_double(Docker::Container, id: "test123").tap do |c|
          allow(c).to receive(:start)
          allow(c).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])
        end
      end

      before do
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(docker_container)
        allow(Docker::Container).to receive(:get).with("test123").and_return(docker_container)
        allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)
      end

      it "generates per-run DATABASE_URL for postgres images" do
        sc = create(:service_container, image: "postgres:16", name: "pg", port: 5432,
          env: { "POSTGRES_USER" => "u", "POSTGRES_PASSWORD" => "p", "POSTGRES_DB" => "d" })
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expected_db = provisioner.send(:per_run_db_name, agent_run)
        expect(result["DATABASE_URL"]).to eq("postgres://u:p@pg:5432/#{expected_db}")
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
              "Test" => [ "CMD", "pg_isready", "-U", "agent", "-d", "agent_test" ]
            )
          )
        )
      end

      it "treats blank postgres env values as missing and uses per-run database" do
        sc = create(:service_container, image: "postgres:16", name: "pg-blank", port: 5432,
          env: { "POSTGRES_USER" => "", "POSTGRES_PASSWORD" => "  ", "POSTGRES_DB" => nil })
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_including(
            "Env" => include(
              "POSTGRES_USER=agent",
              "POSTGRES_PASSWORD=agent",
              "POSTGRES_DB=agent_test"
            )
          )
        )
        expected_db = provisioner.send(:per_run_db_name, agent_run)
        expect(result["DATABASE_URL"]).to eq("postgres://agent:agent@pg-blank:5432/#{expected_db}")
      end

      it "generates REDIS_URL for redis images" do
        sc = create(:service_container, :redis, name: "redis-test", port: 6379)
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expect(result["REDIS_URL"]).to eq("redis://redis-test:6379")
      end

      it "omits Healthcheck key for non-postgres containers" do
        sc = create(:service_container, :redis, name: "redis-nohc", port: 6379)
        create(:project_service_container, project: project, service_container: sc)

        provisioner.provision(agent_run)

        expect(Docker::Container).to have_received(:create).with(
          hash_not_including("Healthcheck")
        )
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
      allow(docker_container).to receive_messages(
        start: nil,
        exec: [ [ "(0 rows)" ], [], 0 ],
        json: { "State" => { "Health" => { "Status" => "healthy" } } }
      )
      allow(Docker::Container).to receive(:get).with("abc123").and_return(docker_container)
      provisioner.provision(agent_run)

      expected_limits = {
        "Memory" => 2 * 1024 * 1024 * 1024, "MemorySwap" => 2 * 1024 * 1024 * 1024,
        "CpuPeriod" => 100_000, "CpuQuota" => 100_000, "PidsLimit" => 200
      }
      expect(Docker::Container).to have_received(:create)
        .with(hash_including("HostConfig" => hash_including(expected_limits)))
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

  describe "metrics collection scheduling" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:agent_run) { create(:agent_run, project: project, issue: issue) }
    let(:service_container) do
      create(:service_container,
        image: "postgres:16",
        name: "metrics-postgres",
        port: 5432,
        env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" })
    end

    before do
      create(:project_service_container, project: project, service_container: service_container)
      allow(NetworkPolicy).to receive(:ensure_network!)
      allow(Docker::Image).to receive(:create)
      docker_container = instance_double(Docker::Container, id: "m123")
      allow(docker_container).to receive(:start)
      allow(docker_container).to receive(:exec).and_return([ [ "(0 rows)" ], [], 0 ])
      allow(Docker::Container).to receive(:create).and_return(docker_container)
      allow(Docker::Container).to receive(:get).with("m123").and_return(docker_container)
      allow(provisioner).to receive_messages(docker_healthcheck_status: nil, tcp_port_open?: true)
    end

    it "silently handles concurrency errors from duplicate metrics job enqueues" do
      allow(ServiceContainerMetricsCollectionJob).to receive(:perform_later)
        .and_raise(GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError)
      allow(Rails.logger).to receive(:info).and_call_original

      expect { provisioner.provision(agent_run) }.not_to raise_error
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "service_provisioner.metrics_job_already_enqueued",
                       service_container_id: service_container.id)
      )
    end
  end

  describe "#cleanup" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:service_container) { create(:service_container, :running) }

    before do
      create(:project_service_container, project: project, service_container: service_container)
    end

    it "drops per-run database and stops containers with no active runs" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ])

      docker_container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get)
        .with(service_container.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec).and_return([ [], [], 0 ])
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      provisioner.cleanup(agent_run)

      expect(docker_container).to have_received(:exec).at_least(:once)
      expect(docker_container).to have_received(:delete).with(force: true, v: true)
      expect(service_container.reload.status).to eq("stopped")
      expect(agent_run.reload.service_container_ids).to eq([])
    end

    it "does not persist other dirty attributes while clearing service containers" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ],
        service_environment: nil)
      old_environment = { "DATABASE_URL" => "postgres://agent:agent@pg:5432/old_attempt" }
      docker_container = instance_double(Docker::Container)

      allow(Docker::Container).to receive(:get)
        .with(service_container.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec).and_return([ [], [], 0 ])
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      agent_run.service_environment = old_environment
      provisioner.cleanup(agent_run)

      expect(agent_run.reload.service_environment).to be_nil
      expect(agent_run.service_container_ids).to eq([])
    end

    it "leaves containers running when other runs still need them" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ])
      create(:agent_run, :running, project: project, issue: issue,
        service_container_ids: [ service_container.id ])

      docker_container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get)
        .with(service_container.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec).and_return([ [], [], 0 ])

      provisioner.cleanup(agent_run)

      expect(service_container.reload.status).to eq("running")
    end

    it "handles empty service_container_ids gracefully" do
      agent_run = create(:agent_run, project: project, issue: issue,
        service_container_ids: [])

      expect { provisioner.cleanup(agent_run) }.not_to raise_error
    end

    it "still deletes the container when stop raises ClientError" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ])

      docker_container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get)
        .with(service_container.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec).and_return([ [], [], 0 ])
      allow(docker_container).to receive(:stop)
        .and_raise(Docker::Error::ClientError, "container already stopped")
      allow(docker_container).to receive(:delete)

      provisioner.cleanup(agent_run)

      expect(docker_container).to have_received(:delete).with(force: true, v: true)
      expect(service_container.reload.status).to eq("stopped")
    end

    it "continues cleanup even if database drop fails" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ service_container.id ])

      docker_container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get)
        .with(service_container.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec)
        .and_raise(Docker::Error::DockerError, "connection refused")
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      expect { provisioner.cleanup(agent_run) }.not_to raise_error
      expect(service_container.reload.status).to eq("stopped")
    end
  end

  describe "per-run database isolation" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:agent_run) { create(:agent_run, project: project, issue: issue) }

    it "generates unique database names per agent run" do
      db_name = provisioner.send(:per_run_db_name, agent_run)
      expect(db_name).to start_with("agent_run_")
      expect(db_name).not_to include("-")
    end

    it "generates distinct database names for stale requeue attempts" do
      first_attempt = provisioner.send(:per_run_db_name, agent_run)

      agent_run.update!(stale_requeue_count: 1)
      second_attempt = provisioner.send(:per_run_db_name, agent_run)

      expect(first_attempt).to end_with("_attempt_0")
      expect(second_attempt).to end_with("_attempt_1")
      expect(second_attempt).not_to eq(first_attempt)
    end

    it "creates a new database when it does not exist" do
      sc = create(:service_container, :running)
      docker_container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)

      # First exec: check existence (not found)
      # Second exec: create database
      call_count = 0
      allow(docker_container).to receive(:exec) do |_cmd|
        call_count += 1
        if call_count == 1
          [ [ "(0 rows)" ], [], 0 ]
        else
          [ [ "CREATE DATABASE" ], [], 0 ]
        end
      end

      db_name = provisioner.send(:per_run_db_name, agent_run)
      expect { provisioner.send(:create_per_run_database, sc, db_name) }.not_to raise_error
      expect(docker_container).to have_received(:exec).twice
    end

    it "quotes database and owner identifiers in create statements" do
      sc = create(:service_container, :running, env: {
        "POSTGRES_USER" => "agent\" WITH SUPERUSER --",
        "POSTGRES_PASSWORD" => "agent",
        "POSTGRES_DB" => "agent_test"
      })
      docker_container = instance_double(Docker::Container)
      commands = []

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec) do |cmd|
        commands << cmd
        commands.one? ? [ [ "(0 rows)" ], [], 0 ] : [ [ "CREATE DATABASE" ], [], 0 ]
      end

      db_name = provisioner.send(:per_run_db_name, agent_run)
      provisioner.send(:create_per_run_database, sc, db_name)

      expect(commands.last).to include("-d", "agent_test")
      expect(commands.last.last).to eq(
        "CREATE DATABASE \"#{db_name}\" OWNER \"agent\"\" WITH SUPERUSER --\""
      )
    end

    it "quotes database identifiers in drop statements" do
      sc = create(:service_container, :running)
      docker_container = instance_double(Docker::Container)
      commands = []

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec) do |cmd|
        commands << cmd
        [ [], [], 0 ]
      end

      db_name = provisioner.send(:per_run_db_name, agent_run)
      provisioner.send(:drop_per_run_database, sc, db_name)

      expect(commands).to all(include("-d", "agent_test"))
      expect(commands.last.last).to eq("DROP DATABASE IF EXISTS \"#{db_name}\"")
    end

    it "drops the database from the stored DATABASE_URL instead of mutable run state" do
      sc = create(:service_container, :running)
      docker_container = instance_double(Docker::Container)
      commands = []
      original_db_name = provisioner.send(:per_run_db_name, agent_run)

      agent_run.update!(
        stale_requeue_count: 1,
        service_environment: { "DATABASE_URL" => "postgres://agent:agent@pg:5432/#{original_db_name}" }
      )

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec) do |cmd|
        commands << cmd
        [ [], [], 0 ]
      end
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      provisioner.cleanup(agent_run.tap { |run| run.service_container_ids = [ sc.id ] })

      expect(commands.last.last).to eq("DROP DATABASE IF EXISTS \"#{original_db_name}\"")
    end

    it "uses the captured stale requeue count when DATABASE_URL is unavailable" do
      sc = create(:service_container, :running)
      docker_container = instance_double(Docker::Container)
      commands = []
      original_db_name = provisioner.send(:per_run_db_name, agent_run, stale_requeue_count: 0)

      agent_run.update!(stale_requeue_count: 1, service_environment: nil)

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec) do |cmd|
        commands << cmd
        [ [], [], 0 ]
      end
      allow(docker_container).to receive_messages(stop: true, delete: true)

      provisioner.cleanup(
        agent_run.tap { |run| run.service_container_ids = [ sc.id ] },
        stale_requeue_count: 0
      )

      expect(commands.last.last).to eq("DROP DATABASE IF EXISTS \"#{original_db_name}\"")
    end

    it "skips legacy shared database URLs during cleanup" do
      sc = create(:service_container, :running)
      docker_container = instance_double(Docker::Container)

      agent_run.update!(
        service_environment: { "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" }
      )

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec)
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      provisioner.cleanup(agent_run.tap { |run| run.service_container_ids = [ sc.id ] })

      expect(docker_container).not_to have_received(:exec)
      expect(docker_container).to have_received(:delete).with(force: true, v: true)
    end

    it "skips configured postgres database URLs during cleanup" do
      sc = create(:service_container, :running, env: {
        "POSTGRES_USER" => "agent",
        "POSTGRES_PASSWORD" => "agent",
        "POSTGRES_DB" => "app_test"
      })
      docker_container = instance_double(Docker::Container)

      agent_run.update!(
        service_environment: { "DATABASE_URL" => "postgres://agent:agent@pg:5432/app_test" }
      )

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec)
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      provisioner.cleanup(agent_run.tap { |run| run.service_container_ids = [ sc.id ] })

      expect(docker_container).not_to have_received(:exec)
      expect(docker_container).to have_received(:delete).with(force: true, v: true)
    end

    it "skips per-run database URLs for a different agent run" do
      sc = create(:service_container, :running)
      docker_container = instance_double(Docker::Container)
      other_run = create(:agent_run, project: project, issue: create(:issue, project: project))
      other_db_name = provisioner.send(:per_run_db_name, other_run)

      agent_run.update!(
        service_environment: { "DATABASE_URL" => "postgres://agent:agent@pg:5432/#{other_db_name}" }
      )

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec)
      allow(docker_container).to receive(:stop)
      allow(docker_container).to receive(:delete)

      provisioner.cleanup(agent_run.tap { |run| run.service_container_ids = [ sc.id ] })

      expect(docker_container).not_to have_received(:exec)
      expect(docker_container).to have_received(:delete).with(force: true, v: true)
    end

    it "logs and continues when Docker transport fails during drop" do
      sc = create(:service_container, :running)
      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_raise(Excon::Error.new("connection reset"))

      expect(Rails.logger).to receive(:warn).with(
        hash_including(
          message: "service_provisioner.database_drop_error",
          db_name: provisioner.send(:per_run_db_name, agent_run),
          service_container: sc.name,
          error: "connection reset"
        )
      )

      db_name = provisioner.send(:per_run_db_name, agent_run)
      expect { provisioner.send(:drop_per_run_database, sc, db_name) }.not_to raise_error
    end

    it "connects psql commands to the configured postgres database" do
      sc = create(:service_container, :running, env: {
        "POSTGRES_USER" => "agent",
        "POSTGRES_PASSWORD" => "agent",
        "POSTGRES_DB" => "app_test"
      })
      docker_container = instance_double(Docker::Container)
      commands = []

      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec) do |cmd|
        commands << cmd
        commands.one? ? [ [ "(0 rows)" ], [], 0 ] : [ [ "CREATE DATABASE" ], [], 0 ]
      end

      db_name = provisioner.send(:per_run_db_name, agent_run)
      provisioner.send(:create_per_run_database, sc, db_name)

      expect(commands).to all(include("-d", "app_test"))
    end

    it "skips creation when database already exists (idempotent)" do
      sc = create(:service_container, :running)
      docker_container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get)
        .with(sc.docker_container_id).and_return(docker_container)
      allow(docker_container).to receive(:exec)
        .and_return([ [ "(1 row)" ], [], 0 ])

      db_name = provisioner.send(:per_run_db_name, agent_run)
      provisioner.send(:create_per_run_database, sc, db_name)
      expect(docker_container).to have_received(:exec).once
    end
  end
end
