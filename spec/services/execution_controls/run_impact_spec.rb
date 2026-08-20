# frozen_string_literal: true

require "rails_helper"

# @spec EXEC-DISABLE-006
# @spec EXEC-DISABLE-007
RSpec.describe ExecutionControls::RunImpact do
  describe "#park_run!" do
    it "records the parked audit event and log when the run transitions to paused" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, project: project)
      allow(Rails.logger).to receive(:info)

      expect {
        described_class.new(control: control).park_run!(agent_run)
      }.to change(AccountActivityEvent, :count).by(1)

      expect(AccountActivityEvent.last.action).to eq("agent_run.execution_parked")
      expect(Rails.logger).to have_received(:info).with(hash_including(message: "execution_control.run_parked"))
      expect(agent_run.reload.status).to eq("paused")
    end

    it "does not record an audit event or log when the run finished before the lock was acquired" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, project: project)
      allow(Rails.logger).to receive(:info)

      # Simulate the run completing between affected_runs being computed and
      # the with_lock block running inside park_run!.
      allow(agent_run).to receive(:with_lock).and_wrap_original do |original, &block|
        agent_run.update_columns(status: "completed", completed_at: Time.current)
        original.call(&block)
      end

      expect {
        described_class.new(control: control).park_run!(agent_run)
      }.not_to change(AccountActivityEvent, :count)

      expect(Rails.logger).not_to have_received(:info).with(hash_including(message: "execution_control.run_parked"))
    end

    it "does not record an audit event or log when the run is already parked by this same control" do
      project = create(:project)
      control = create(:execution_control, :project_scope, project: project)
      agent_run = create(:agent_run, :paused, project: project, external_metadata: {
        "execution_control" => {
          "control_id" => control.id,
          "scope" => control.scope,
          "mode" => control.mode,
          "parked_at" => Time.current.iso8601
        }
      })
      allow(Rails.logger).to receive(:info)

      expect {
        described_class.new(control: control).park_run!(agent_run)
      }.not_to change(AccountActivityEvent, :count)

      expect(Rails.logger).not_to have_received(:info).with(hash_including(message: "execution_control.run_parked"))
    end
  end
end
