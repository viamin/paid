# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeRecommendation do
  subject(:recommendation) { build(:knowledge_recommendation) }

  describe "associations" do
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:recommendation_type) }
    it { is_expected.to validate_inclusion_of(:recommendation_type).in_array(described_class::RECOMMENDATION_TYPES) }
    it { is_expected.to validate_presence_of(:priority) }
    it { is_expected.to validate_inclusion_of(:priority).in_array(described_class::PRIORITIES) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:description) }
  end

  describe "scopes" do
    let(:project) { create(:project) }

    describe ".pending" do
      it "returns only pending recommendations" do
        pending_rec = create(:knowledge_recommendation, project: project, status: "pending")
        create(:knowledge_recommendation, project: project, status: "accepted")

        expect(described_class.pending).to contain_exactly(pending_rec)
      end
    end

    describe ".accepted" do
      it "returns only accepted recommendations" do
        create(:knowledge_recommendation, project: project, status: "pending")
        accepted_rec = create(:knowledge_recommendation, project: project, status: "accepted")

        expect(described_class.accepted).to contain_exactly(accepted_rec)
      end
    end

    describe ".by_priority" do
      it "orders by priority level" do
        create(:knowledge_recommendation, project: project, priority: "high")
        create(:knowledge_recommendation, project: project, priority: "low")
        create(:knowledge_recommendation, project: project, priority: "critical")
        create(:knowledge_recommendation, project: project, priority: "medium")

        priorities = described_class.by_priority.pluck(:priority)
        expect(priorities).to eq(%w[low medium high critical])
      end
    end
  end

  describe "#dismiss!" do
    let(:recommendation) { create(:knowledge_recommendation) }

    it "sets status to dismissed with reason and timestamp" do
      freeze_time do
        recommendation.dismiss!(reason: "Not relevant")

        expect(recommendation.reload).to have_attributes(
          status: "dismissed",
          dismissal_reason: "Not relevant",
          dismissed_at: Time.current
        )
      end
    end
  end

  describe "#accept!" do
    let(:recommendation) { create(:knowledge_recommendation) }

    it "sets status to accepted" do
      recommendation.accept!
      expect(recommendation.reload.status).to eq("accepted")
    end
  end
end
