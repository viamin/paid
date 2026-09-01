# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-001
# @spec SESSION-SUMMARY-004
RSpec.describe AgentRunSessionSummary do
  describe "validations" do
    it "is valid with default factory attributes" do
      expect(build(:agent_run_session_summary)).to be_valid
    end

    it "requires a summary" do
      record = build(:agent_run_session_summary, summary: nil)
      expect(record).not_to be_valid
      expect(record.errors[:summary]).to be_present
    end

    it "requires status to be a known value" do
      record = build(:agent_run_session_summary, status: "bogus")
      expect(record).not_to be_valid
      expect(record.errors[:status]).to be_present
    end

    it "requires project to match the agent run's project" do
      other_project = create(:project)
      record = build(:agent_run_session_summary, project: other_project)
      expect(record).not_to be_valid
      expect(record.errors[:project]).to be_present
    end

    it "requires the linked issue to belong to the same project" do
      agent_run = create(:agent_run, :completed)
      other_issue = create(:issue)
      record = build(:agent_run_session_summary, agent_run: agent_run, project: agent_run.project,
        issue: other_issue)
      expect(record).not_to be_valid
      expect(record.errors[:issue]).to be_present
    end

    it "requires the linked change intent to belong to the same project" do
      agent_run = create(:agent_run, :completed)
      other_change_intent = create(:change_intent)
      record = build(:agent_run_session_summary, agent_run: agent_run, project: agent_run.project,
        change_intent: other_change_intent, status: "promoted", promoted_at: Time.current,
        promoted_by: create(:user))
      expect(record).not_to be_valid
      expect(record.errors[:change_intent]).to be_present
    end

    it "enforces one summary per agent run" do
      agent_run = create(:agent_run, :completed)
      create(:agent_run_session_summary, agent_run: agent_run, project: agent_run.project)

      duplicate = build(:agent_run_session_summary, agent_run: agent_run, project: agent_run.project)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#observation? / #promoted?" do
    it "defaults to observation" do
      record = build(:agent_run_session_summary)
      expect(record).to be_observation
      expect(record).not_to be_promoted
    end

    it "reflects promoted status" do
      record = build(:agent_run_session_summary, :promoted)
      expect(record).to be_promoted
      expect(record).not_to be_observation
    end
  end

  describe "#linked_change_intent" do
    it "returns the promoted change intent when it still exists" do
      record = create(:agent_run_session_summary, :promoted)

      expect(record.linked_change_intent).to eq(record.change_intent)
    end

    it "returns nil after the promoted draft change intent is discarded" do
      record = create(:agent_run_session_summary, :promoted)

      ChangeIntents::DiscardDraft.call(change_intent: record.change_intent)

      expect(record.reload.linked_change_intent).to be_nil
    end
  end

  describe "#promote!" do
    it "transitions status and links the change intent and promoting user" do
      record = create(:agent_run_session_summary)
      user = create(:user)
      change_intent = create(:change_intent, project: record.project)

      record.promote!(change_intent: change_intent, user: user)

      expect(record.status).to eq("promoted")
      expect(record.change_intent).to eq(change_intent)
      expect(record.promoted_by).to eq(user)
      expect(record.promoted_at).to be_present
    end

    it "raises when already promoted" do
      record = create(:agent_run_session_summary, :promoted)

      expect {
        record.promote!(change_intent: record.change_intent, user: record.promoted_by)
      }.to raise_error(ArgumentError, "already promoted")
    end
  end
end
