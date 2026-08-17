# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExecutionControl do
  describe "run impact" do
    # @spec EXEC-DISABLE-005
    it "cancels active project runs in emergency mode and records audit events" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, :emergency, project: project)

      expect {
        described_class.transaction do
          control.update!(enabled: true, enabled_at: Time.current, reason: "Emergency shutdown")
          ExecutionControls::RunImpact.new(control: control).enable!
        end
      }.to have_enqueued_job(AgentRunCancellationJob).with(agent_run.id)
        .and change(AccountActivityEvent, :count).by(2)

      expect(agent_run.reload.status).to eq("cancelled")
      expect(AccountActivityEvent.order(:id).last.action).to eq("agent_run.cancelled")
    end

    # @spec EXEC-DISABLE-006
    it "parks active project runs in capacity mode and resumes them when disabled" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, project: project)
      allow(AgentRuns::Cancel).to receive(:call)

      control.update!(enabled: true, enabled_at: Time.current, reason: "Capacity reduction")
      ExecutionControls::RunImpact.new(control: control).enable!

      agent_run.reload
      expect(agent_run.status).to eq("paused")
      expect(agent_run.external_metadata.dig("execution_control", "control_id")).to eq(control.id)

      control.update!(enabled: false, disabled_at: Time.current)
      ExecutionControls::RunImpact.new(control: control).disable!

      expect(agent_run.reload.status).to eq("queued")
      expect(agent_run.external_metadata).not_to have_key("execution_control")
    end
  end
end
