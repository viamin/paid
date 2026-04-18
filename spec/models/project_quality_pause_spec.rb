# frozen_string_literal: true

require "rails_helper"

RSpec.describe Project do
  describe "quality pause" do
    let(:project) { create(:project) }

    describe "#quality_paused?" do
      it "returns false when quality_paused_at is nil" do
        expect(project.quality_paused?).to be false
      end

      it "returns true when quality_paused_at is set" do
        project.update!(quality_paused_at: Time.current)
        expect(project.quality_paused?).to be true
      end
    end

    describe "#quality_pause_threshold" do
      it "returns nil when no threshold is configured" do
        expect(project.quality_pause_threshold).to be_nil
      end

      it "returns the configured threshold as a float" do
        project.update!(review_settings: { "quality_pause_threshold" => 0.5 })
        expect(project.quality_pause_threshold).to eq(0.5)
      end
    end

    describe "#quality_pause!" do
      it "sets quality_paused_at and creates an audit event" do
        result = project.quality_pause!(score: 0.3, threshold: 0.5)

        expect(result).to be true
        expect(project.reload.quality_paused?).to be true
        expect(project.quality_pause_metadata).to include(
          "composite_score" => 0.3,
          "threshold" => 0.5
        )

        event = project.quality_pause_events.last
        expect(event.event_type).to eq("paused")
        expect(event.composite_score).to eq(0.3)
        expect(event.threshold).to eq(0.5)
      end

      it "returns false if already paused" do
        project.update!(quality_paused_at: Time.current)
        result = project.quality_pause!(score: 0.3, threshold: 0.5)
        expect(result).to be false
      end

      it "records the triggering agent_run" do
        agent_run = create(:agent_run, :completed, project: project)
        project.quality_pause!(score: 0.3, threshold: 0.5, agent_run: agent_run)

        event = project.quality_pause_events.last
        expect(event.agent_run).to eq(agent_run)
      end
    end

    describe "#quality_resume!" do
      before do
        project.update!(
          quality_paused_at: 1.hour.ago,
          quality_pause_metadata: { threshold: 0.5 }
        )
      end

      it "clears quality_paused_at and creates an audit event" do
        result = project.quality_resume!

        expect(result).to be true
        expect(project.reload.quality_paused?).to be false
        expect(project.quality_pause_metadata).to eq({})

        event = project.quality_pause_events.last
        expect(event.event_type).to eq("resumed")
      end

      it "returns false if not paused" do
        project.update!(quality_paused_at: nil)
        result = project.quality_resume!
        expect(result).to be false
      end
    end
  end
end
