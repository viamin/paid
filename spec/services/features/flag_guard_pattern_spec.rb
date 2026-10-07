# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec RDR-ROLLOUT-GUARD-003
# @spec RDR-ROLLOUT-GUARD-004
RSpec.describe Features::FlagGuardPattern do
  describe ".applicable?" do
    it "is true when the repository profile confirms the FeatureFlags pattern" do
      project = build_stubbed(
        :project,
        primary_language: "Ruby",
        repo_profile: { "feature_flags_pattern" => true }
      )

      expect(described_class.applicable?(project)).to be true
    end

    it "is true for a polyglot repository that confirms the FeatureFlags pattern" do
      project = build_stubbed(
        :project,
        repo_profile: { "languages" => %w[javascript ruby], "feature_flags_pattern" => true }
      )

      expect(described_class.applicable?(project)).to be true
    end

    # @spec RDR-ROLLOUT-GUARD-004
    it "is false for a Ruby project without evidence of the FeatureFlags pattern" do
      project = build_stubbed(:project, primary_language: "Ruby")

      expect(described_class.applicable?(project)).to be false
    end

    it "is false for a non-ruby primary language" do
      project = build_stubbed(:project, primary_language: "GDScript")

      expect(described_class.applicable?(project)).to be false
    end

    it "is false for a non-ruby repo profile" do
      project = build_stubbed(:project, repo_profile: { "languages" => %w[python] })

      expect(described_class.applicable?(project)).to be false
    end

    it "is false when no language has been detected" do
      project = build_stubbed(:project, primary_language: nil)

      expect(described_class.applicable?(project)).to be false
    end

    it "is false for projects that do not expose detected languages" do
      expect(described_class.applicable?(nil)).to be false
      expect(described_class.applicable?(OpenStruct.new)).to be false
    end
  end
end
