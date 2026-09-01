# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-004
RSpec.describe Knowledge::SessionSummaries::Promote do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :completed, project: project, issue: issue) }
  let(:user) { create(:user) }
  let(:session_summary) do
    create(:agent_run_session_summary, project: project, agent_run: agent_run, issue: issue,
      summary: "Implemented rate limiting.",
      decisions: [ "Used a sliding window." ],
      assumptions: [ "Assumed Redis is available." ],
      failures: [ "In-memory counters failed under load." ],
      follow_ups: [ "Add a dashboard panel." ],
      learnings: [ "Config lives in config/rate_limits.yml." ])
  end

  describe ".call" do
    it "creates a draft change intent seeded from the summary" do
      change_intent = described_class.call(session_summary: session_summary, user: user)

      expect(change_intent).to be_persisted
      expect(change_intent.status).to eq("draft")
      expect(change_intent.project).to eq(project)
      expect(change_intent.issue).to eq(issue)
      expect(change_intent.intent).to eq("Implemented rate limiting.")
      expect(change_intent.behavior).to include("Add a dashboard panel.")
      expect(change_intent.constraints).to include("Assumed Redis is available.")
      expect(change_intent.decisions_made).to include("Used a sliding window.")
      expect(change_intent.decisions_made).to include("In-memory counters failed under load.")
      expect(change_intent.decisions_made).to include("Config lives in config/rate_limits.yml.")
    end

    it "marks the session summary as promoted and links the change intent and user" do
      change_intent = described_class.call(session_summary: session_summary, user: user)

      session_summary.reload
      expect(session_summary).to be_promoted
      expect(session_summary.change_intent).to eq(change_intent)
      expect(session_summary.promoted_by).to eq(user)
      expect(session_summary.promoted_at).to be_present
    end

    it "raises and creates nothing when the summary is already promoted" do
      other_agent_run = create(:agent_run, :completed, project: project)
      promoted_summary = create(:agent_run_session_summary, :promoted, project: project, agent_run: other_agent_run)

      expect {
        expect {
          described_class.call(session_summary: promoted_summary, user: user)
        }.to raise_error(ArgumentError, "already promoted")
      }.not_to change(ChangeIntent, :count)
    end
  end
end
