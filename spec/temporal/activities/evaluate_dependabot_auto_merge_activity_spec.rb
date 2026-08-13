# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::EvaluateDependabotAutoMergeActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    let(:project) { create(:project, auto_merge_mode: "dependabot_only") }

    it "enqueues DependabotAutoMergeJob when auto-merge is enabled" do
      expect {
        activity.execute(project_id: project.id)
      }.to have_enqueued_job(DependabotAutoMergeJob).with(project.id)
    end

    it "returns evaluated: true when auto-merge is enabled" do
      result = activity.execute(project_id: project.id)

      expect(result).to eq(evaluated: true)
    end

    it "does not enqueue when auto-merge is off" do
      project.update!(auto_merge_mode: "off")

      expect {
        activity.execute(project_id: project.id)
      }.not_to have_enqueued_job(DependabotAutoMergeJob)
    end

    it "returns evaluated: false with reason when auto-merge is off" do
      project.update!(auto_merge_mode: "off")

      result = activity.execute(project_id: project.id)

      expect(result).to eq(evaluated: false, reason: "disabled")
    end

    it "returns project_missing when project not found" do
      result = activity.execute(project_id: -1)

      expect(result).to eq(evaluated: false, project_missing: true)
    end
  end
end
