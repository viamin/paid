# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ProvisionServicesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  before do
    # Default: DetectServices finds nothing (prevents GitHub API calls in existing tests)
    allow(Projects::DetectServices).to receive(:call).and_return(
      instance_double(Projects::DetectServices::Result, detected: [], matched: [], unmatched: [], apply: [])
    )
  end

  describe "#execute" do
    it "provisions service containers and returns environment variables" do
      provisioner = instance_double(Containers::ServiceProvisioner)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:provision)
        .with(agent_run, network: NetworkPolicy::NETWORK_NAME)
        .and_return({ "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" })
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:service_container_ids).and_return([ 1 ])
      allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:service_environment]).to eq({ "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" })
    end

    it "returns empty environment when no services configured" do
      provisioner = instance_double(Containers::ServiceProvisioner)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:provision)
        .with(agent_run, network: NetworkPolicy::NETWORK_NAME).and_return({})
      allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:service_container_ids).and_return([])

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:service_environment]).to eq({})
    end

    it "uses the same network selected for the agent container" do
      provisioner = instance_double(Containers::ServiceProvisioner)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::INFRA_NETWORK_NAME)
      allow(provisioner).to receive(:provision)
        .with(agent_run, network: NetworkPolicy::INFRA_NETWORK_NAME).and_return({})
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:service_container_ids).and_return([])

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:service_environment]).to eq({})
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "when the project has no service containers configured" do
      let(:service_container) { create(:service_container, account: project.account, image: "postgres:16", name: "Dev Postgres", port: 5432) }
      let(:detect_result) do
        instance_double(
          Projects::DetectServices::Result,
          detected: [ { service: "postgres", source: "Gemfile", dependency: "pg" } ],
          matched: [ service_container ],
          unmatched: []
        )
      end

      before do
        allow(Projects::DetectServices).to receive(:call).with(project: project).and_return(detect_result)
        allow(detect_result).to receive(:apply).with(project).and_return([ "Dev Postgres" ])
      end

      it "auto-detects and links service containers before provisioning" do
        provisioner = instance_double(Containers::ServiceProvisioner)
        allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
        allow(provisioner).to receive(:provision).and_return({ "DATABASE_URL" => "postgres://..." })
        allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
        allow(agent_run).to receive(:service_container_ids).and_return([])

        activity.execute(agent_run_id: agent_run.id)

        expect(Projects::DetectServices).to have_received(:call).with(project: project)
        expect(detect_result).to have_received(:apply).with(project)
      end

      it "skips auto-detect when the project already has service containers" do
        create(:project_service_container, project: project, service_container: service_container)

        provisioner = instance_double(Containers::ServiceProvisioner)
        allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
        allow(provisioner).to receive(:provision).and_return({})
        allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
        allow(agent_run).to receive(:service_container_ids).and_return([ service_container.id ])

        activity.execute(agent_run_id: agent_run.id)

        expect(Projects::DetectServices).not_to have_received(:call)
      end

      it "continues without services when auto-detect fails" do
        allow(Projects::DetectServices).to receive(:call).and_raise(GithubClient::RateLimitError)

        provisioner = instance_double(Containers::ServiceProvisioner)
        allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
        allow(provisioner).to receive(:provision).and_return({})
        allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
        allow(agent_run).to receive(:service_container_ids).and_return([])

        expect { activity.execute(agent_run_id: agent_run.id) }.not_to raise_error
      end

      it "logs a warning when needed services have no matching account container" do
        unmatched_result = instance_double(
          Projects::DetectServices::Result,
          detected: [ { service: "postgres", source: "Gemfile", dependency: "pg" } ],
          matched: [],
          unmatched: [ { service: "postgres", source: "Gemfile" } ]
        )
        allow(unmatched_result).to receive(:apply).with(project).and_return([])
        allow(Projects::DetectServices).to receive(:call).and_return(unmatched_result)
        allow(activity).to receive(:logger).and_return(Rails.logger)

        provisioner = instance_double(Containers::ServiceProvisioner)
        allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
        allow(provisioner).to receive(:provision).and_return({})
        allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
        allow(agent_run).to receive(:service_container_ids).and_return([])

        expect(Rails.logger).to receive(:warn).with(
          hash_including(message: "agent_execution.service_containers_unmatched", project_id: project.id)
        )

        activity.execute(agent_run_id: agent_run.id)
      end
    end
  end
end
