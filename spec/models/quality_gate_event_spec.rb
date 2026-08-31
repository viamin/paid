# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityGateEvent do
  describe "validations" do
    it "is valid with valid attributes" do
      project = create(:project)
      threshold = create(:quality_threshold, :gate, project: project)
      run = create(:agent_run, project: project)
      metric = create(:quality_metric, agent_run: run)

      event = build(:quality_gate_event,
        project: project,
        quality_threshold: threshold,
        quality_metric: metric)
      expect(event).to be_valid
    end

    it "requires valid event_type" do
      event = build(:quality_gate_event)
      event.event_type = "invalid"
      expect(event).not_to be_valid
    end

    it "requires score_value" do
      event = build(:quality_gate_event)
      event.score_value = nil
      expect(event).not_to be_valid
    end
  end

  describe "scopes" do
    let(:project) { create(:project) }
    let(:threshold) { create(:quality_threshold, :gate, project: project) }
    let(:run) { create(:agent_run, project: project) }
    let(:metric) { create(:quality_metric, agent_run: run) }

    it ".triggers returns only trigger events" do
      trigger = create(:quality_gate_event,
        project: project, quality_threshold: threshold,
        quality_metric: metric, event_type: "trigger")
      run2 = create(:agent_run, :with_custom_prompt, project: project)
      metric2 = create(:quality_metric, :human, agent_run: run2)
      create(:quality_gate_event, :recovery,
        project: project, quality_threshold: threshold,
        quality_metric: metric2)

      expect(described_class.triggers).to contain_exactly(trigger)
    end

    it ".recoveries returns only recovery events" do
      create(:quality_gate_event,
        project: project, quality_threshold: threshold,
        quality_metric: metric, event_type: "trigger")
      run2 = create(:agent_run, :with_custom_prompt, project: project)
      metric2 = create(:quality_metric, :human, agent_run: run2)
      recovery = create(:quality_gate_event, :recovery,
        project: project, quality_threshold: threshold,
        quality_metric: metric2)

      expect(described_class.recoveries).to contain_exactly(recovery)
    end
  end
end
