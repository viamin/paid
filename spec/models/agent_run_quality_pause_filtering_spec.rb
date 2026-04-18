# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun do
  describe ".peek_next_queued_run quality pause filtering" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "excludes automatic runs from quality-paused projects" do
      project.update!(quality_paused_at: Time.current)
      create(:agent_run, :queued, :automatic, project: project)

      expect(described_class.peek_next_queued_run).to be_nil
    end

    it "allows manual runs from quality-paused projects" do
      project.update!(quality_paused_at: Time.current)
      manual_run = create(:agent_run, :queued, :manual, project: project)

      expect(described_class.peek_next_queued_run).to eq(manual_run)
    end

    it "allows automatic runs from non-paused projects" do
      auto_run = create(:agent_run, :queued, :automatic, project: project)
      expect(described_class.peek_next_queued_run).to eq(auto_run)
    end
  end
end
