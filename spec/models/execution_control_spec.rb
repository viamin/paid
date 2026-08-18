# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExecutionControl do
  describe "run impact" do
    # @spec EXEC-DISABLE-005
    it "cancels active project runs when emergency mode is enabled and records audit events" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, :emergency, project: project)

      expect {
        control.update!(enabled: true, enabled_at: Time.current, reason: "Emergency shutdown")
      }.to have_enqueued_job(AgentRunCancellationJob).with(agent_run.id)
        .and change(AccountActivityEvent, :count).by(2)

      expect(agent_run.reload.status).to eq("cancelled")
      expect(AccountActivityEvent.order(:id).last.action).to eq("agent_run.cancelled")
    end

    # @spec EXEC-DISABLE-006
    it "parks active project runs in capacity mode and resumes them when disabled" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      workflow_id = agent_run.temporal_workflow_id
      control = create(:execution_control, :project_scope, project: project)
      allow(AgentRuns::Cancel).to receive(:call)

      expect {
        control.update!(enabled: true, enabled_at: Time.current, reason: "Capacity reduction")
      }.to have_enqueued_job(ExecutionControlParkCleanupJob).with(agent_run.id, workflow_id, nil)

      agent_run.reload
      expect(agent_run.status).to eq("paused")
      expect(agent_run.external_metadata.dig("execution_control", "control_id")).to eq(control.id)

      control.update!(enabled: false, disabled_at: Time.current)

      expect(agent_run.reload.status).to eq("queued")
      expect(agent_run.external_metadata).not_to have_key("execution_control")
    end

    it "resumes runs parked by the same control when an emergency control is cleared" do
      project = create(:project)
      control = create(:execution_control, :project_scope, :emergency, project: project)
      agent_run = create(:agent_run, :paused, project: project, external_metadata: {
        "execution_control" => {
          "control_id" => control.id,
          "scope" => control.scope,
          "mode" => control.mode,
          "parked_at" => Time.current.iso8601
        }
      })

      control.update_columns(enabled: true, enabled_at: Time.current)
      control.update!(enabled: false, disabled_at: Time.current)

      expect(agent_run.reload.status).to eq("queued")
      expect(agent_run.external_metadata).not_to have_key("execution_control")
    end

    it "limits backend emergency cancellation to the backend account" do
      account = create(:account)
      owner = create(:user, :owner, account: account)
      project = create(:project, account: account, created_by: owner)
      host = create(:docker_host, account: account, identifier: "default")
      local_run = create(:agent_run, :running, :with_temporal, project: project, container_host: host.identifier)

      other_project = create(:project)
      create(:docker_host, account: other_project.account, identifier: "default")
      other_run = create(:agent_run, :running, :with_temporal, project: other_project, container_host: "default")

      control = create(:execution_control, :backend_scope, :emergency, docker_host: host)

      control.update!(enabled: true, enabled_at: Time.current, reason: "Backend failure")

      expect(local_run.reload.status).to eq("cancelled")
      expect(other_run.reload.status).to eq("running")
    end
  end
end
