# frozen_string_literal: true

require "rails_helper"

# Integration coverage for RDR-054: proves that a Postgres service container
# provisioned through the runner-boundary delegation path
# (Activities::ProvisionServicesActivity -> ExecutionRunners.resolve_for ->
# LocalDockerRunner#provision_services -> Containers::ServiceProvisioner)
# results in DATABASE_URL reaching both agent_run.service_environment and the
# ExecutionRunners::RunSpec that would be handed to the agent container.
#
# @spec CONTAINER-RUNTIME-032
RSpec.describe "Postgres service provisioning through the ExecutionRunners boundary", type: :model do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, project: project, issue: issue) }
  let(:service_container) do
    create(:service_container,
      account: project.account,
      image: "postgres:16",
      name: "test-postgres",
      port: 5432,
      env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" })
  end

  before do
    create(:project_service_container, project: project, service_container: service_container)
    allow(Projects::DetectServices).to receive(:call).and_return(
      instance_double(Projects::DetectServices::Result, detected: [], matched: [], unmatched: [], apply: [])
    )
    allow(Containers::Provision).to receive(:ensure_network!)
    allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)

    docker_container = instance_double(Docker::Container, id: "abc123")
    allow(Docker::Image).to receive(:create)
    allow(Docker::Container).to receive(:create).and_return(docker_container)
    allow(docker_container).to receive(:start)
    allow(Containers::TcpHealthProbe).to receive(:open?).and_return(true)
    allow(Docker::Container).to receive(:get).with("abc123").and_return(docker_container)
    allow(docker_container).to receive_messages(
      exec: [ [ "(0 rows)" ], [], 0 ],
      json: { "State" => { "Health" => { "Status" => "healthy" } } }
    )
  end

  it "delivers DATABASE_URL through ProvisionServicesActivity into agent_run.service_environment" do
    result = Activities::ProvisionServicesActivity.new.execute(agent_run_id: agent_run.id)

    expect(result[:service_environment]).to include("DATABASE_URL")
    expect(agent_run.reload.service_environment["DATABASE_URL"]).to match(%r{\Apostgres://agent:agent@})
  end

  it "propagates DATABASE_URL into the RunSpec built for the agent container" do
    Activities::ProvisionServicesActivity.new.execute(agent_run_id: agent_run.id)
    agent_run.reload

    spec = ExecutionRunners::RunSpec.from_agent_run(agent_run)

    expect(spec.environment["DATABASE_URL"]).to eq(agent_run.service_environment["DATABASE_URL"])
    expect(spec.services).to contain_exactly(
      have_attributes(name: "test-postgres", type: :database, image: "postgres:16")
    )
    expect(spec.services.first.env["DATABASE_URL"]).to eq(agent_run.service_environment["DATABASE_URL"])
  end

  # @spec CONTAINER-RUNTIME-032
  describe "Activities::CleanupServicesActivity tearing down all service containers via the runner boundary" do
    let(:redis_container) { create(:service_container, :running, :redis, account: project.account) }
    let(:postgres_container) { create(:service_container, :running, account: project.account) }

    it "stops and deletes every provisioned service container, not just the first" do
      create(:project_service_container, project: project, service_container: redis_container)
      create(:project_service_container, project: project, service_container: postgres_container)
      run = create(:agent_run, :completed, project: project, issue: issue,
        service_container_ids: [ redis_container.id, postgres_container.id ])

      redis_docker = instance_double(Docker::Container)
      postgres_docker = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get).with(redis_container.docker_container_id).and_return(redis_docker)
      allow(Docker::Container).to receive(:get).with(postgres_container.docker_container_id).and_return(postgres_docker)
      allow(redis_docker).to receive(:exec).and_return([ [], [], 0 ])
      allow(postgres_docker).to receive(:exec).and_return([ [], [], 0 ])
      allow(redis_docker).to receive_messages(stop: nil, delete: nil)
      allow(postgres_docker).to receive_messages(stop: nil, delete: nil)

      Activities::CleanupServicesActivity.new.execute(agent_run_id: run.id)

      expect(redis_docker).to have_received(:delete).with(force: true, v: true)
      expect(postgres_docker).to have_received(:delete).with(force: true, v: true)
      expect(redis_container.reload.status).to eq("stopped")
      expect(postgres_container.reload.status).to eq("stopped")
      expect(run.reload.service_container_ids).to eq([])
    end
  end
end
