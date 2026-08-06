# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::Settings do
  # @spec CONFIG-PROFILES-006
  describe "canonical operating-mode coverage" do
    let(:field_keys) { described_class.profile_target_keys }

    it "requires every registered profile to cover the field set exactly" do
      Configuration::Profiles::Registry.all.each do |profile|
        expect(profile.targets.keys).to match_array(field_keys),
          lambda { "#{profile.name} must cover every operating-mode target (#{field_keys - profile.targets.keys} missing)" }
      end
    end

    it "keeps target descriptor columns aligned with the live schema" do
      described_class.target_descriptors.each do |descriptor|
        next unless descriptor.column

        expect(Project.columns_hash).to include(descriptor.column),
          "#{descriptor.key} maps to missing column #{descriptor.column.inspect}"
      end
    end

    it "keeps enum descriptor options aligned with the model constants" do
      expect(described_class.fetch("auto_merge_mode").options).to match_array(%w[off dependabot_only all])
      expect(described_class.fetch("merge_method").options).to match_array(Project::MERGE_METHODS)
      expect(described_class.fetch("auto_release_granularity").options).to match_array(Project::AUTO_RELEASE_GRANULARITIES)
      expect(described_class.fetch("adoption_mode").options).to match_array(Project::ADOPTION_MODES)
    end

    it "fails when a mode-relevant project column lacks profile coverage or exemption" do
      covered = described_class.attribute_columns
      accounted_for = covered + described_class.excluded_attribute_columns

      unaccounted = Project.columns_hash.keys.select do |column|
        described_class::MODE_RELEVANT_COLUMN_PATTERNS.any? do |pattern|
          pattern.is_a?(Regexp) ? pattern.match?(column) : column == pattern
        end
      end.reject { |column| accounted_for.include?(column) }

      expect(unaccounted).to be_empty,
        lambda {
          "These operating-mode columns lack chat profile coverage: #{unaccounted.inspect}. " \
          "Add them to Configuration::Profiles::Settings and every profile target, " \
          "or explicitly exempt them when they are not posture levers."
        }
    end
  end
end
