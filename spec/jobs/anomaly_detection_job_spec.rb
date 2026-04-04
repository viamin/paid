# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnomalyDetectionJob do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :completed, :with_metrics, project: project) }

  describe "#perform" do
    it "calls Anomalies::Detect" do
      allow(Anomalies::Detect).to receive(:call).and_return([])

      described_class.perform_now(agent_run.id)

      expect(Anomalies::Detect).to have_received(:call).with(agent_run)
    end

    it "skips unfinished runs" do
      running_run = create(:agent_run, :running, project: project)
      allow(Anomalies::Detect).to receive(:call)

      described_class.perform_now(running_run.id)

      expect(Anomalies::Detect).not_to have_received(:call)
    end

    it "discards missing agent runs" do
      allow(Anomalies::Detect).to receive(:call)

      expect { described_class.perform_now(-1) }.not_to raise_error
      expect(Anomalies::Detect).not_to have_received(:call)
    end
  end
end
