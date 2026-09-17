# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-001
# @spec INTENT-AMENDMENT-002
RSpec.describe IntentConformanceResolution do
  describe "one-PR exception bound" do
    it "records a valid exception bound to actor, PR, and head" do
      resolution = build(:intent_conformance_resolution)

      expect(resolution).to be_valid
      expect(resolution.exception?).to be(true)
    end

    it "rejects an exception that marks an approved product commitment changed" do
      resolution = build(:intent_conformance_resolution, changes_behavior: true)

      expect(resolution).not_to be_valid
      expect(resolution.errors[:base]).to include(
        "approved product commitments can only change through a design amendment"
      )
    end

    it "rejects require_within_scope resolutions that change the product contract" do
      resolution = build(:intent_conformance_resolution,
        resolution_type: "require_within_scope", changes_scope: true)

      expect(resolution).not_to be_valid
    end

    it "rejects an exception changing constraints, scope, or acceptance criteria" do
      aggregate_failures do
        [ :changes_constraints, :changes_scope, :changes_acceptance_criteria ].each do |flag|
          resolution = build(:intent_conformance_resolution, flag => true)

          expect(resolution).not_to be_valid
        end
      end
    end
  end

  describe "product-contract changes require a design amendment" do
    it "accepts a design_amendment resolution that changes the product contract" do
      amendment = create(:design_amendment)
      resolution = build(:intent_conformance_resolution,
        resolution_type: "design_amendment",
        design_amendment: amendment,
        changes_acceptance_criteria: true)

      expect(resolution).to be_valid
      expect(resolution.product_contract_changed?).to be(true)
    end

    it "rejects a design_amendment resolution without a linked amendment" do
      resolution = build(:intent_conformance_resolution, resolution_type: "design_amendment")

      expect(resolution).not_to be_valid
      expect(resolution.errors[:design_amendment]).to be_present
    end
  end

  describe "head binding" do
    it "binds the resolution to one record per issue head" do
      existing = create(:intent_conformance_resolution)

      duplicate = build(:intent_conformance_resolution,
        issue: existing.issue, pr_head_sha: existing.pr_head_sha)

      expect(duplicate).not_to be_valid
    end

    it "targets only pull-request issues" do
      resolution = build(:intent_conformance_resolution, issue: create(:issue))

      expect(resolution).not_to be_valid
      expect(resolution.errors[:issue]).to include("must be a pull request")
    end
  end
end
