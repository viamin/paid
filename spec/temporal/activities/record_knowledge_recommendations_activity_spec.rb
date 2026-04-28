# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordKnowledgeRecommendationsActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    let(:recommendations) do
      [
        {
          recommendation_type: "add_collector",
          collector_type: "database_schema",
          priority: "high",
          description: "Collects database schemas",
          evidence: { gap_frequency: 5 }
        },
        {
          recommendation_type: "remove_collector",
          collector_type: "language_stat",
          priority: "low",
          description: "Rarely referenced",
          evidence: { usage_count: 2 }
        }
      ]
    end

    let(:input) { { project_id: project.id, recommendations: recommendations } }

    it "creates new recommendation records" do
      result = activity.execute(input)

      expect(result[:created_count]).to eq(2)
      expect(project.knowledge_recommendations.pending.count).to eq(2)
    end

    it "sets correct attributes on created records" do
      activity.execute(input)

      rec = project.knowledge_recommendations.find_by(collector_type: "database_schema")
      expect(rec.recommendation_type).to eq("add_collector")
      expect(rec.priority).to eq("high")
      expect(rec.status).to eq("pending")
      expect(rec.evidence).to include("gap_frequency" => 5)
    end

    context "when a duplicate pending recommendation exists" do
      before do
        create(:knowledge_recommendation,
          project: project,
          recommendation_type: "add_collector",
          collector_type: "database_schema",
          status: "pending")
      end

      it "skips the duplicate" do
        result = activity.execute(input)

        expect(result[:created_count]).to eq(1)
        expect(project.knowledge_recommendations.pending.where(collector_type: "database_schema").count).to eq(1)
      end
    end

    context "when stale pending recommendations exist" do
      before do
        create(:knowledge_recommendation,
          project: project,
          recommendation_type: "add_collector",
          collector_type: "old_collector",
          status: "pending")
      end

      it "dismisses stale recommendations" do
        result = activity.execute(input)

        expect(result[:dismissed_count]).to eq(1)
        stale = project.knowledge_recommendations.find_by(collector_type: "old_collector")
        expect(stale.status).to eq("dismissed")
        expect(stale.dismissal_reason).to eq("no_longer_flagged")
      end
    end

    context "with invalid recommendation types" do
      let(:recommendations) do
        [ { recommendation_type: "invalid_type", collector_type: "foo", priority: "high", description: "Bad" } ]
      end

      it "skips invalid recommendations" do
        result = activity.execute(input)

        expect(result[:created_count]).to eq(0)
      end
    end

    context "with empty collector_type" do
      let(:recommendations) do
        [ { recommendation_type: "add_collector", collector_type: "", priority: "high", description: "Missing type" } ]
      end

      it "skips non-gap recommendations without collector_type" do
        result = activity.execute(input)

        expect(result[:created_count]).to eq(0)
      end
    end

    context "with knowledge_gap recommendation without collector_type" do
      let(:recommendations) do
        [
          {
            recommendation_type: "knowledge_gap",
            collector_type: nil,
            priority: "high",
            description: "Missing database schema context for migration questions"
          }
        ]
      end

      it "creates the recommendation with nil collector_type" do
        result = activity.execute(input)

        expect(result[:created_count]).to eq(1)
        rec = project.knowledge_recommendations.pending.find_by(recommendation_type: "knowledge_gap")
        expect(rec.collector_type).to be_nil
        expect(rec.description).to eq("Missing database schema context for migration questions")
      end

      it "deduplicates against existing nil-collector pending recommendations" do
        create(:knowledge_recommendation,
          project: project,
          recommendation_type: "knowledge_gap",
          collector_type: nil,
          status: "pending")

        result = activity.execute(input)

        expect(result[:created_count]).to eq(0)
      end
    end
  end
end
