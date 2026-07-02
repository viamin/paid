# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun, :no_db do
  describe "#provision_container" do
    let(:project) { double(id: 42) }
    let(:agent_run) do
      project_record = project

      described_class.allocate.tap do |run|
        run.define_singleton_method(:project) { project_record }
        run.define_singleton_method(:project_id) { project_record.id }
        run.define_singleton_method(:worktree_path) { nil }
        run.define_singleton_method(:container_id) { nil }
        run.define_singleton_method(:persisted_updates) { @persisted_updates ||= [] }
        run.define_singleton_method(:update!) do |**attrs|
          persisted_updates << attrs
        end
      end
    end

    it "persists the claimed pool entry host instead of the process-global backend" do
      pooled_service = instance_double(Containers::Provision)
      pooled_result = Containers::Provision::Result.success(
        container_id: "warm-container",
        container_host: "remote",
        service: pooled_service,
        pool_entry_id: 123
      )
      pool_manager = instance_double(Containers::PoolManager, acquire: pooled_result)

      allow(Containers::PoolManager).to receive(:new).with(project: project).and_return(pool_manager)

      agent_run.provision_container

      expect(agent_run.persisted_updates).to include(container_id: "warm-container", container_host: "remote")
    end

    it "persists the host returned by fresh provisioning" do
      provision_service = instance_double(Containers::Provision)
      result = Containers::Provision::Result.success(container_id: "fresh-container", container_host: "remote")
      pool_manager = instance_double(Containers::PoolManager, acquire: nil)

      allow(Containers::PoolManager).to receive(:new).with(project: project).and_return(pool_manager)
      allow(Containers::Provision).to receive(:new).and_return(provision_service)
      allow(provision_service).to receive(:provision).and_return(result)
      allow(PoolReplenishmentJob).to receive(:perform_later)

      agent_run.provision_container

      expect(agent_run.persisted_updates).to include(container_id: "fresh-container", container_host: "remote")
      expect(PoolReplenishmentJob).to have_received(:perform_later).with(project.id)
    end
  end
end
