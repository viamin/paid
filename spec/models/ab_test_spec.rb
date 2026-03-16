# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTest do
  describe "associations" do
    it { is_expected.to belong_to(:prompt) }
    it { is_expected.to belong_to(:control_version).class_name("PromptVersion") }
    it { is_expected.to belong_to(:winner_variant).class_name("AbTestVariant").optional }
    it { is_expected.to have_many(:ab_test_variants).dependent(:destroy) }
    it { is_expected.to have_many(:ab_test_assignments).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_numericality_of(:min_samples_per_variant).only_integer.is_greater_than(0) }
  end

  describe "#start!" do
    it "transitions from draft to running" do
      test = create(:ab_test, status: "draft")
      test.start!

      expect(test.reload.status).to eq("running")
      expect(test.started_at).to be_present
    end

    it "raises when not draft" do
      test = create(:ab_test, status: "running", started_at: Time.current)
      expect { test.start! }.to raise_error(ActiveRecord::RecordInvalid, /cannot start a test/)
    end
  end

  describe "#complete!" do
    it "transitions from running to completed" do
      test = create(:ab_test, status: "running", started_at: Time.current)
      test.complete!

      expect(test.reload.status).to eq("completed")
      expect(test.completed_at).to be_present
    end

    it "accepts an optional winner" do
      test = create(:ab_test, status: "running", started_at: Time.current)
      variant = create(:ab_test_variant, ab_test: test)
      test.complete!(winner: variant)

      expect(test.reload.winner_variant).to eq(variant)
    end
  end

  describe "#cancel!" do
    it "transitions to cancelled from draft" do
      test = create(:ab_test, status: "draft")
      test.cancel!
      expect(test.reload.status).to eq("cancelled")
    end

    it "transitions to cancelled from running" do
      test = create(:ab_test, status: "running", started_at: Time.current)
      test.cancel!
      expect(test.reload.status).to eq("cancelled")
    end

    it "raises when already completed" do
      test = create(:ab_test, status: "completed", started_at: 1.hour.ago, completed_at: Time.current)
      expect { test.cancel! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#sufficient_samples?" do
    it "returns true when all variants have enough samples" do
      test = create(:ab_test, min_samples_per_variant: 2)
      create(:ab_test_variant, ab_test: test, is_control: true, sample_count: 5)
      create(:ab_test_variant, ab_test: test, sample_count: 3)

      expect(test.sufficient_samples?).to be true
    end

    it "returns false when any variant lacks samples" do
      test = create(:ab_test, min_samples_per_variant: 30)
      create(:ab_test_variant, ab_test: test, is_control: true, sample_count: 30)
      create(:ab_test_variant, ab_test: test, sample_count: 5)

      expect(test.sufficient_samples?).to be false
    end
  end
end
