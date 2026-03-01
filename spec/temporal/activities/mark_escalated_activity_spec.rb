# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkEscalatedActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    context "when issue exists" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      it "updates pr_review_phase to escalated" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end
    end

    context "when issue is missing" do
      it "returns updated: false" do
        result = activity.execute(issue_id: -1)

        expect(result[:updated]).to be false
      end
    end
  end
end
