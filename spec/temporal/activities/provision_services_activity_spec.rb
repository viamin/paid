# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ProvisionServicesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe "#execute" do
    it "provisions service containers and returns environment variables" do
      provisioner = instance_double(Containers::ServiceProvisioner)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:provision)
        .with(agent_run, network: NetworkPolicy::NETWORK_NAME)
        .and_return({ "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" })
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:service_container_ids).and_return([ 1 ])
      allow(NetworkPolicy).to receive(:agent_network).and_return(NetworkPolicy::NETWORK_NAME)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:service_environment]).to eq({ "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_test" })
    end

    it "returns empty environment when no services configured" do
      provisioner = instance_double(Containers::ServiceProvisioner)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:provision)
        .with(agent_run, network: NetworkPolicy::NETWORK_NAME).and_return({})
      allow(NetworkPolicy).to receive(:agent_network).and_return(NetworkPolicy::NETWORK_NAME)
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
  end
end
