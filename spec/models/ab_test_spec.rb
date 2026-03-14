# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTest do
  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:prompt) }
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:winner_variant).class_name("AbTestVariant").optional }
    it { is_expected.to have_many(:variants).class_name("AbTestVariant").dependent(:destroy) }
  end

  describe "#start!" do
    it "transitions from draft to running" do
      test = create(:ab_test, :with_variants)

      test.start!

      expect(test.status).to eq("running")
      expect(test.started_at).to be_present
    end

    it "raises when test has fewer than 2 variants" do
      test = create(:ab_test)

      expect { test.start! }.to raise_error(RuntimeError, /at least 2 variants/)
    end
  end

  describe "#pause!" do
    it "transitions from running to paused" do
      test = create(:ab_test, :running, :with_variants)

      test.pause!

      expect(test.status).to eq("paused")
    end
  end

  describe "#complete!" do
    it "transitions from running to completed" do
      test = create(:ab_test, :running, :with_variants)

      test.complete!

      expect(test.status).to eq("completed")
      expect(test.completed_at).to be_present
    end
  end

  describe "#total_samples" do
    it "sums sample counts from all variants" do
      test = create(:ab_test, :with_variants)
      test.variants.first.update!(sample_count: 10)
      test.variants.last.update!(sample_count: 15)

      expect(test.total_samples).to eq(25)
    end
  end
end
