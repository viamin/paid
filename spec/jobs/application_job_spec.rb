# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationJob do
  describe "tenant account resolution" do
    it "extracts project_id from QualityAlerts::CheckGateJob keyword arguments" do
      account = instance_double(Account)
      project = instance_double(Project, account: account)
      job = QualityAlerts::CheckGateJob.new(project_id: 123)

      allow(Project).to receive(:find_by).and_call_original
      allow(Project).to receive(:find_by).with(id: 123).and_return(project)

      expect(job.send(:tenant_account)).to eq(account)
    end

    it "extracts agent_run_id from AgentRunCancellationJob arguments" do
      account = instance_double(Account)
      project = instance_double(Project, account: account)
      agent_run = instance_double(AgentRun, project: project)
      job = AgentRunCancellationJob.new(123)

      allow(AgentRun).to receive(:includes).and_call_original
      allow(AgentRun).to receive(:includes).with(:project).and_return(AgentRun)
      allow(AgentRun).to receive(:find_by).with(id: 123).and_return(agent_run)

      expect(job.send(:tenant_account)).to eq(account)
    end
  end
end
