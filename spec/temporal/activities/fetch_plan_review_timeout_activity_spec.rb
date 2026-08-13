# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::FetchPlanReviewTimeoutActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    let(:project) { create(:project, plan_review_timeout_hours: 48) }

    it "returns the project plan review timeout" do
      result = activity.execute(project_id: project.id)

      expect(result[:plan_review_timeout_hours]).to eq(48)
    end

    it "returns the default 24 hours and project_missing when project is missing" do
      result = activity.execute(project_id: -1)

      expect(result[:project_missing]).to be true
      expect(result[:plan_review_timeout_hours]).to eq(24)
    end

    context "with default timeout" do
      let(:project) { create(:project) }

      it "returns the default 24 hours" do
        result = activity.execute(project_id: project.id)

        expect(result[:plan_review_timeout_hours]).to eq(24)
      end
    end
  end
end
