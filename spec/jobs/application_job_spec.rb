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
  end
end
