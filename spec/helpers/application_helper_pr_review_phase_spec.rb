# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :no_db do
  describe "#pr_review_phase_badge" do
    it "renders 'In Review' for draft and restarted phases" do
      expect(helper.pr_review_phase_badge("draft")).to include("In Review", "bg-blue-100")
      expect(helper.pr_review_phase_badge("restarted")).to include("In Review", "bg-blue-100")
    end

    it "renders 'Ready' (matching the paid-ready label) when the review gate passes" do
      badge = helper.pr_review_phase_badge("ready")

      expect(badge).to include("Ready")
      expect(badge).to include("bg-green-100")
    end

    it "renders 'Escalated' (matching the paid-escalated label)" do
      badge = helper.pr_review_phase_badge("escalated")

      expect(badge).to include("Escalated")
      expect(badge).to include("bg-orange-100")
    end

    it "renders 'Merged' (matching the paid-auto-merged label)" do
      badge = helper.pr_review_phase_badge("merged")

      expect(badge).to include("Merged")
      expect(badge).to include("bg-purple-100")
    end

    it "falls back to 'In Review' for nil or unknown phases" do
      expect(helper.pr_review_phase_badge(nil)).to include("In Review")
      expect(helper.pr_review_phase_badge("bogus")).to include("In Review")
    end

    it "adds a pluralized review-round tooltip when review_count is positive" do
      expect(helper.pr_review_phase_badge("draft", review_count: 1)).to include('title="1 review round"')
      expect(helper.pr_review_phase_badge("draft", review_count: 3)).to include('title="3 review rounds"')
    end

    it "omits the tooltip when there have been no review rounds" do
      expect(helper.pr_review_phase_badge("draft", review_count: 0)).not_to include("title=")
    end
  end
end
