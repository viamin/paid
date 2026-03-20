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
    it { is_expected.to validate_numericality_of(:min_samples_per_variant).only_integer.is_greater_than_or_equal_to(2) }
    it { is_expected.to validate_numericality_of(:confidence_threshold).is_greater_than(0).is_less_than_or_equal_to(1) }
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

    it "raises a friendly error when another test is already running for the same prompt" do
      running_test = create(:ab_test, status: "running", started_at: Time.current)
      draft_test = create(:ab_test, status: "draft", prompt: running_test.prompt)

      expect { draft_test.start! }.to raise_error(ActiveRecord::RecordInvalid, /already running/)
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

  describe "#cached_or_compute_analysis" do
    let(:ab_test) { create(:ab_test, status: "running", started_at: Time.current, min_samples_per_variant: 2) }
    let!(:control) { create(:ab_test_variant, ab_test: ab_test, is_control: true, sample_count: 5) }
    let(:analysis_result) { AbTests::Analyze::Result.new(status: :no_significant_difference, confidence: nil, improvement: nil) }

    before do
      create(:ab_test_variant, ab_test: ab_test, sample_count: 5)
      allow(AbTests::Analyze).to receive(:call).and_return(analysis_result)
    end

    it "computes and persists analysis on first call with persist: true" do
      result = ab_test.cached_or_compute_analysis(persist: true)

      expect(AbTests::Analyze).to have_received(:call).with(ab_test: ab_test)
      expect(result.status).to eq(:no_significant_difference)
      expect(ab_test.reload.cached_analysis).to be_present
    end

    it "returns cached result on subsequent calls when samples haven't changed" do
      ab_test.cached_or_compute_analysis(persist: true)
      ab_test.cached_or_compute_analysis(persist: true)

      expect(AbTests::Analyze).to have_received(:call).once
    end

    it "recomputes when sample counts cross a bucket boundary" do
      ab_test.cached_or_compute_analysis(persist: true)

      # Move sample count past the next bucket boundary (ANALYSIS_INTERVAL = 5)
      control.update_columns(sample_count: 10)
      ab_test.ab_test_variants.reload
      ab_test.cached_or_compute_analysis(persist: true)

      expect(AbTests::Analyze).to have_received(:call).twice
    end

    it "returns nil on cache miss when persist: false" do
      result = ab_test.cached_or_compute_analysis(persist: false)

      expect(result).to be_nil
      expect(AbTests::Analyze).not_to have_received(:call)
    end

    it "returns stale cached result when persist: false and cache key differs" do
      ab_test.cached_or_compute_analysis(persist: true)
      control.update_columns(sample_count: 10)

      result = ab_test.cached_or_compute_analysis(persist: false)

      expect(result.status).to eq(:no_significant_difference)
      expect(AbTests::Analyze).to have_received(:call).once
    end

    it "recomputes when total samples cross a bucket boundary even if no single variant does" do
      # Start with control=3, treatment=2 (total=5, bucket=5)
      control.update_columns(sample_count: 3)
      ab_test.ab_test_variants.where(is_control: false).update_all(sample_count: 2)
      ab_test.ab_test_variants.reload
      ab_test.cached_or_compute_analysis(persist: true)

      # Bump to control=6, treatment=4 (total=10, bucket=10)
      # Neither variant crosses its own bucket boundary (both stay in bucket 5),
      # but total crosses from bucket 5 to bucket 10.
      control.update_columns(sample_count: 6)
      ab_test.ab_test_variants.where(is_control: false).update_all(sample_count: 4)
      ab_test.ab_test_variants.reload
      ab_test.cached_or_compute_analysis(persist: true)

      expect(AbTests::Analyze).to have_received(:call).twice
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
