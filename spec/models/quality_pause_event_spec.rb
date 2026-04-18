# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityPauseEvent do
  describe "validations" do
    it "validates event_type inclusion" do
      event = build(:quality_pause_event, event_type: "invalid")
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to be_present
    end

    it "accepts valid event types" do
      %w[paused resumed].each do |type|
        event = build(:quality_pause_event, event_type: type)
        expect(event).to be_valid
      end
    end

    it "validates composite_score range" do
      event = build(:quality_pause_event, composite_score: 1.5)
      expect(event).not_to be_valid
    end

    it "allows nil composite_score" do
      event = build(:quality_pause_event, composite_score: nil)
      expect(event).to be_valid
    end
  end

  describe "associations" do
    it "belongs to project" do
      event = build(:quality_pause_event)
      expect(event.project).to be_present
    end

    it "optionally belongs to agent_run" do
      event = build(:quality_pause_event, agent_run: nil)
      expect(event).to be_valid
    end
  end

  describe "scopes" do
    let(:project) { create(:project) }

    before do
      create(:quality_pause_event, :paused, project: project)
      create(:quality_pause_event, :resumed, project: project)
    end

    it ".pauses returns only pause events" do
      expect(described_class.pauses.count).to eq(1)
      expect(described_class.pauses.first.event_type).to eq("paused")
    end

    it ".resumes returns only resume events" do
      expect(described_class.resumes.count).to eq(1)
      expect(described_class.resumes.first.event_type).to eq("resumed")
    end
  end
end
