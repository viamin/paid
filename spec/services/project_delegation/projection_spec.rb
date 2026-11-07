# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-005
RSpec.describe ProjectDelegation::Projection do
  let(:project) do
    create(:project, delegation_posture: posture)
  end

  describe "effective_posture" do
    context "when posture is not set" do
      let(:project) { create(:project, delegation_posture: nil) }

      it "defaults to conservative" do
        projection = described_class.new(project: project)
        expect(projection.effective_posture).to eq(described_class::CONSERVATIVE_POSTURE)
      end
    end

    context "when posture is conservative" do
      let(:posture) { described_class::CONSERVATIVE_POSTURE }

      it "returns conservative" do
        projection = described_class.new(project: project)
        expect(projection.effective_posture).to eq(described_class::CONSERVATIVE_POSTURE)
      end
    end

    context "when posture is bounded_delivery" do
      let(:posture) { described_class::BOUNDED_DELIVERY_POSTURE }

      it "returns bounded_delivery" do
        projection = described_class.new(project: project)
        expect(projection.effective_posture).to eq(described_class::BOUNDED_DELIVERY_POSTURE)
      end
    end
  end

  describe "delegated?" do
    context "when posture is conservative" do
      let(:posture) { described_class::CONSERVATIVE_POSTURE }

      it "returns false" do
        projection = described_class.new(project: project)
        expect(projection.delegated?).to be(false)
      end
    end

    context "when posture is bounded_delivery" do
      let(:posture) { described_class::BOUNDED_DELIVERY_POSTURE }

      it "returns true" do
        projection = described_class.new(project: project)
        expect(projection.delegated?).to be(true)
      end
    end
  end

  describe "conservative?" do
    context "when posture is conservative" do
      let(:posture) { described_class::CONSERVATIVE_POSTURE }

      it "returns true" do
        projection = described_class.new(project: project)
        expect(projection.conservative?).to be(true)
      end
    end

    context "when posture is bounded_delivery" do
      let(:posture) { described_class::BOUNDED_DELIVERY_POSTURE }

      it "returns false" do
        projection = described_class.new(project: project)
        expect(projection.conservative?).to be(false)
      end
    end
  end

  describe "mandatory_reviews" do
    context "when posture is conservative" do
      let(:posture) { described_class::CONSERVATIVE_POSTURE }

      it "includes all review types" do
        projection = described_class.new(project: project)
        reviews = projection.mandatory_reviews

        expect(reviews).to include("feature_intent_approval")
        expect(reviews).to include("acceptance_criteria_review")
        expect(reviews).to include("repository_review_merge")
        expect(reviews).to include("release_deployment")
        expect(reviews).to include("bounded_implementation_choices")
      end
    end

    context "when posture is bounded_delivery" do
      let(:posture) { described_class::BOUNDED_DELIVERY_POSTURE }

      it "includes only critical reviews" do
        projection = described_class.new(project: project)
        reviews = projection.mandatory_reviews

        expect(reviews).to include("feature_intent_approval")
        expect(reviews).to include("acceptance_criteria_review")
        expect(reviews).to include("repository_review_merge")
        expect(reviews).not_to include("bounded_implementation_choices")
      end
    end
  end

  describe "to_h" do
    let(:posture) { described_class::CONSERVATIVE_POSTURE }
    let(:user) { create(:user) }

    before do
      project.update(delegation_authorized_by: user, delegation_authorized_at: Time.current)
    end

    it "returns a hash with projection data" do
      projection = described_class.new(project: project)
      hash = projection.to_h

      expect(hash).to include(
        effective_posture: described_class::CONSERVATIVE_POSTURE,
        delegated: false,
        conservative: true,
        authorized_by: user.name,
        mandatory_reviews: an_instance_of(Array)
      )
    end
  end
end
