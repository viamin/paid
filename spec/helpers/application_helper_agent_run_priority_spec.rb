# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :db do
  describe "AGENT_RUN_PRIORITY_STYLES" do
    it "defines a style for every AgentRun::QUEUE_PRIORITIES tier" do
      expect(ApplicationHelper::AGENT_RUN_PRIORITY_STYLES.keys).to include(*AgentRun::QUEUE_PRIORITIES.keys)
    end
  end

  describe "#agent_run_priority_badge" do
    it "renders the styled badge for a real tier" do
      run = create(:agent_run, trigger_type: "manual")

      badge = helper.agent_run_priority_badge(run)

      expect(badge).to include("bg-sky-100")
      expect(badge).to include("1 - Manual")
    end

    it "falls back to the unknown style when the tier has no matching style entry" do
      run = create(:agent_run, trigger_type: "manual")
      allow(run).to receive(:queue_priority_tier).and_return(:not_a_real_tier)

      badge = helper.agent_run_priority_badge(run)

      expect(badge).to include("bg-gray-100")
    end
  end
end
