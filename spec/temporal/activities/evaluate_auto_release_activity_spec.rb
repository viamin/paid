# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::EvaluateAutoReleaseActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    let(:project) { create(:project, auto_release_granularity: "all") }

    it "enqueues AutoReleaseEvaluationJob when auto-release is enabled" do
      expect {
        activity.execute(project_id: project.id)
      }.to have_enqueued_job(AutoReleaseEvaluationJob).with(project.id)
    end

    it "returns evaluated: true when auto-release is enabled" do
      result = activity.execute(project_id: project.id)

      expect(result).to eq(evaluated: true)
    end

    it "does not enqueue when auto-release is disabled" do
      project.update!(auto_release_granularity: "off")

      expect {
        activity.execute(project_id: project.id)
      }.not_to have_enqueued_job(AutoReleaseEvaluationJob)
    end

    it "returns evaluated: false with reason when auto-release is disabled" do
      project.update!(auto_release_granularity: "off")

      result = activity.execute(project_id: project.id)

      expect(result).to eq(evaluated: false, reason: "disabled")
    end

    it "enqueues when auto-release is disabled but a PR activation is present" do
      project.update!(auto_release_granularity: "off")
      allow(Automation::FeatureActivation).to receive(:any_pull_request_feature_enabled?)
        .with(project:, feature: "auto_release").and_return(true)

      expect {
        activity.execute(project_id: project.id)
      }.to have_enqueued_job(AutoReleaseEvaluationJob).with(project.id)
    end

    it "returns project_missing when project not found" do
      result = activity.execute(project_id: -1)

      expect(result).to eq(evaluated: false, project_missing: true)
    end
  end
end
