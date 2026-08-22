# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExecutionControl do
  describe "audit timestamps" do
    it "stamps enabled_at automatically when toggled to true" do
      project = create(:project)
      control = create(:execution_control, :project_scope, project: project)

      expect(control.enabled_at).to be_nil
      expect(control.disabled_at).to be_nil

      before = Time.current
      control.update!(enabled: true)
      after = Time.current

      expect(control.reload.enabled_at).to be_between(before, after)
      expect(control.reload.disabled_at).to be_nil
    end

    it "stamps disabled_at automatically when toggled to false" do
      project = create(:project)
      control = create(:execution_control, :project_scope, :enabled, project: project)

      expect(control.enabled_at).to be_present

      before = Time.current
      control.update!(enabled: false)
      after = Time.current

      expect(control.reload.disabled_at).to be_between(before, after)
    end

    it "does not stamp timestamps when enabled is unchanged" do
      project = create(:project)
      control = create(:execution_control, :project_scope, :enabled, project: project)
      original_enabled_at = control.enabled_at

      control.update!(reason: "Operator notes")

      expect(control.reload.enabled_at).to be_within(1.second).of(original_enabled_at)
      expect(control.reload.disabled_at).to be_nil
    end
  end

  describe "run impact" do
    # @spec EXEC-DISABLE-005
    it "cancels active project runs when emergency mode is enabled and records audit events" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, :emergency, project: project)

      expect {
        control.update!(enabled: true, reason: "Emergency shutdown")
      }.to have_enqueued_job(AgentRunCancellationJob).with(agent_run.id)
        .and change(AccountActivityEvent, :count).by(2)
        .and change(ExecutionAuditEvent, :count).by(1)

      expect(agent_run.reload.status).to eq("cancelled")
      expect(AccountActivityEvent.order(:id).last.action).to eq("agent_run.cancelled")
      expect(ExecutionAuditEvent.order(:id).last).to have_attributes(
        event_name: "execution.emergency_disable_changed",
        actor_id: "execution_controls.run_impact"
      )
    end

    # @spec EXEC-DISABLE-006
    it "parks active project runs in capacity mode and resumes them when disabled" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      workflow_id = agent_run.temporal_workflow_id
      control = create(:execution_control, :project_scope, project: project)
      allow(AgentRuns::Cancel).to receive(:call)

      expect {
        control.update!(enabled: true, reason: "Capacity reduction")
      }.to have_enqueued_job(ExecutionControlParkCleanupJob).with(agent_run.id, workflow_id, nil)

      agent_run.reload
      expect(agent_run.status).to eq("paused")
      expect(agent_run.external_metadata.dig("execution_control", "control_id")).to eq(control.id)

      control.update!(enabled: false)

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

      control.update_columns(enabled: true)
      control.update!(enabled: false)

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

      control.update!(enabled: true, reason: "Backend failure")

      expect(local_run.reload.status).to eq("cancelled")
      expect(other_run.reload.status).to eq("running")
    end

    it "re-applies impact when mode escalates from capacity to emergency while enabled" do
      project = create(:project)
      parked_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, project: project)

      control.update!(enabled: true, reason: "Capacity reduction")
      expect(parked_run.reload.status).to eq("paused")

      new_run = create(:agent_run, :running, :with_temporal, project: project)

      expect {
        control.update!(mode: "emergency")
      }.to have_enqueued_job(AgentRunCancellationJob).with(new_run.id)
        .and change(AccountActivityEvent, :count).by(2)

      expect(new_run.reload.status).to eq("cancelled")
      expect(parked_run.reload.status).to eq("paused")
    end

    it "does not re-apply impact when mode changes while disabled" do
      project = create(:project)
      create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, project: project)

      expect {
        control.update!(mode: "emergency")
      }.not_to change(AccountActivityEvent, :count)
    end

    # @spec EXEC-DISABLE-007
    it "still cancels active runs when recording the control audit event raises" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, :emergency, project: project)
      allow(Audit::RecordEvent).to receive(:call).with(hash_including(action: "execution_control.enabled")).and_raise(StandardError, "audit db down")
      allow(Audit::RecordEvent).to receive(:call).with(hash_including(action: "agent_run.cancelled")).and_call_original

      control.update!(enabled: true, reason: "Emergency shutdown")

      expect(agent_run.reload.status).to eq("cancelled")
    end

    # @spec EXEC-DISABLE-006 @spec EXEC-DISABLE-007
    it "still parks active runs when recording the control audit event raises" do
      project = create(:project)
      agent_run = create(:agent_run, :running, :with_temporal, project: project)
      control = create(:execution_control, :project_scope, project: project)
      allow(Audit::RecordEvent).to receive(:call).with(hash_including(action: "execution_control.enabled")).and_raise(StandardError, "audit db down")
      allow(Audit::RecordEvent).to receive(:call).with(hash_including(action: "agent_run.execution_parked")).and_call_original

      control.update!(enabled: true, reason: "Capacity reduction")

      expect(agent_run.reload.status).to eq("paused")
    end

    # @spec EXEC-DISABLE-007
    it "records an audit event per affected account for a global control toggle" do
      project_a = create(:project)
      project_b = create(:project)
      create(:agent_run, :running, :with_temporal, project: project_a)
      create(:agent_run, :running, :with_temporal, project: project_b)
      control = create(:execution_control, :global, :emergency)

      expect {
        control.update!(enabled: true, reason: "Global emergency shutdown")
      }.to change(AccountActivityEvent, :count).by_at_least(2)

      global_events = AccountActivityEvent.where(action: "execution_control.enabled")
      expect(global_events.pluck(:account_id)).to contain_exactly(project_a.account_id, project_b.account_id)
      expect(global_events.pluck(:subject_id).uniq).to eq([ control.id ])
    end

    # @spec EXEC-DISABLE-007
    it "only attributes a global disable audit event to accounts with runs parked by this control" do
      project_a = create(:project)
      project_b = create(:project)
      create(:agent_run, :running, :with_temporal, project: project_a)
      control = create(:execution_control, :global)
      control.update!(enabled: true, reason: "Global capacity reduction")

      # Unrelated run paused for a different reason (e.g. stale-detector
      # parking) -- must not be attributed to this control's disable event.
      create(:agent_run, :paused, project: project_b, external_metadata: {})

      control.update!(enabled: false)

      global_events = AccountActivityEvent.where(action: "execution_control.disabled")
      expect(global_events.pluck(:account_id)).to contain_exactly(project_a.account_id)
    end

    # @spec EXEC-DISABLE-007
    it "does not raise when recording a global control audit event fails for one account" do
      project_a = create(:project)
      project_b = create(:project)
      create(:agent_run, :running, :with_temporal, project: project_a)
      create(:agent_run, :running, :with_temporal, project: project_b)
      control = create(:execution_control, :global, :emergency)
      allow(Audit::RecordEvent).to receive(:call).and_call_original
      allow(Audit::RecordEvent).to receive(:call).with(hash_including(action: "execution_control.enabled", account: project_a.account)).and_raise(StandardError, "audit db down")

      expect { control.update!(enabled: true, reason: "Global emergency shutdown") }.not_to raise_error

      expect(AccountActivityEvent.where(action: "execution_control.enabled", account: project_b.account)).to be_present
    end
  end
end
