# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::Create do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:variant_version) { prompt.create_version!(template: "Variant template {{title}}") }

  describe ".call" do
    it "creates an A/B test with control and variant" do
      test = described_class.call(
        prompt: prompt,
        name: "Test experiment",
        variant_version_ids: [ variant_version.id ]
      )

      expect(test).to be_persisted
      expect(test.status).to eq("draft")
      expect(test.control_version).to eq(prompt.current_version)
      expect(test.ab_test_variants.count).to eq(2)
      expect(test.ab_test_variants.find_by(is_control: true).prompt_version).to eq(prompt.prompt_versions.first)
    end

    it "raises when prompt has no current version" do
      prompt_without_version = create(:prompt, :global)

      expect {
        described_class.call(
          prompt: prompt_without_version,
          name: "Test",
          variant_version_ids: [ 1 ]
        )
      }.to raise_error(ArgumentError, /current version/)
    end

    it "raises when no variant versions provided" do
      expect {
        described_class.call(prompt: prompt, name: "Test", variant_version_ids: [])
      }.to raise_error(ArgumentError, /at least one/)
    end

    it "raises when too many variants provided" do
      versions = 4.times.map { prompt.create_version!(template: "v#{_1}") }

      expect {
        described_class.call(prompt: prompt, name: "Test", variant_version_ids: versions.map(&:id))
      }.to raise_error(ArgumentError, /maximum/)
    end

    it "raises when prompt already has a running test" do
      create(:ab_test, prompt: prompt, status: "running", started_at: Time.current)

      expect {
        described_class.call(prompt: prompt, name: "Second test", variant_version_ids: [ variant_version.id ])
      }.to raise_error(ArgumentError, /running/)
    end

    it "accepts custom min_samples_per_variant and confidence_threshold" do
      test = described_class.call(
        prompt: prompt,
        name: "Custom thresholds",
        variant_version_ids: [ variant_version.id ],
        min_samples_per_variant: 50,
        confidence_threshold: 0.99
      )

      expect(test.min_samples_per_variant).to eq(50)
      expect(test.confidence_threshold).to eq(0.99)
    end
  end
end
