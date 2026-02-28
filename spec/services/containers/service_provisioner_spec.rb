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
        allow(provisioner).to receive(:tcp_port_open?).and_return(true)

        result = provisioner.provision(agent_run)

        expect(result).to include("DATABASE_URL")
        expect(result["DATABASE_URL"]).to eq("postgres://agent:agent@test-postgres:5432/agent_test")
        expect(agent_run.reload.service_container_ids).to eq([ service_container.id ])
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
        allow(provisioner).to receive(:tcp_port_open?).and_return(true)

        result = provisioner.provision(agent_run)

        expect(result).to include("DATABASE_URL")
        expect(service_container.reload.docker_container_id).to eq("new456")
      end
    end

    context "with environment variable generation" do
      before do
        allow(Docker::Image).to receive(:create)
        allow(Docker::Container).to receive(:create).and_return(
          instance_double(Docker::Container, id: "test123")
        )
        allow(Docker::Container).to receive(:create).and_return(
          instance_double(Docker::Container, id: "test123").tap { |c| allow(c).to receive(:start) }
        )
        allow(provisioner).to receive(:tcp_port_open?).and_return(true)
      end

      it "generates DATABASE_URL for postgres images" do
        sc = create(:service_container, image: "postgres:16", name: "pg", port: 5432,
          env: { "POSTGRES_USER" => "u", "POSTGRES_PASSWORD" => "p", "POSTGRES_DB" => "d" })
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expect(result["DATABASE_URL"]).to eq("postgres://u:p@pg:5432/d")
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
        create(:user_setting, allowed_service_images: [ "custom:1.0" ])
        sc = create(:service_container, image: "custom:1.0", name: "my-svc", port: 8080)
        create(:project_service_container, project: project, service_container: sc)

        result = provisioner.provision(agent_run)
        expect(result["SERVICE_MY_SVC_HOST"]).to eq("my-svc")
        expect(result["SERVICE_MY_SVC_PORT"]).to eq("8080")
      end
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
