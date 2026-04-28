# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoMerge::Signals do
  describe ".build" do
    it "defaults boolean fields to false" do
      signals = described_class.build(issue_id: 1, pr_number: 42)

      expect(signals.owner_approved?).to be false
      expect(signals.checks_green?).to be false
      expect(signals.mergeable?).to be false
      expect(signals.review_feedback_clear?).to be false
      expect(signals.blocking_reviews_complete?).to be false
      expect(signals.reviews_fresh?).to be false
      expect(signals.bot_authored?).to be false
      expect(signals.dependabot_eligible?).to be false
    end

    it "preserves issue_id and pr_number" do
      signals = described_class.build(issue_id: 7, pr_number: 99)

      expect(signals.issue_id).to eq(7)
      expect(signals.pr_number).to eq(99)
    end

    it "accepts keyword overrides for boolean fields" do
      signals = described_class.build(
        issue_id: 1,
        pr_number: 42,
        owner_approved: true,
        checks_green: true,
        mergeable: true,
        review_feedback_clear: true,
        blocking_reviews_complete: true,
        reviews_fresh: true
      )

      expect(signals.owner_approved?).to be true
      expect(signals.checks_green?).to be true
      expect(signals.mergeable?).to be true
      expect(signals.review_feedback_clear?).to be true
      expect(signals.blocking_reviews_complete?).to be true
      expect(signals.reviews_fresh?).to be true
    end

    it "accepts bot-authored fields" do
      signals = described_class.build(
        issue_id: 1,
        pr_number: 42,
        bot_authored: true,
        dependabot_eligible: true
      )

      expect(signals.bot_authored?).to be true
      expect(signals.dependabot_eligible?).to be true
    end
  end
end
