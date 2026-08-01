# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Registry do
  describe ".for_scope" do
    it "registers all project-scope checks, including network checks" do
      expect(described_class.for_scope(:project)).to contain_exactly(
        HealthChecks::Checks::Project::AutoMergeWithoutOwner,
        HealthChecks::Checks::Project::ReviewWithoutBot,
        HealthChecks::Checks::Project::ReviewBotNotInstalled,
        HealthChecks::Checks::Project::EmptyAllowlist,
        HealthChecks::Checks::Project::MissingGitHubCredential,
        HealthChecks::Checks::Project::SensitiveDataFreeModel
      )
    end

    it "registers runner-scope network checks" do
      expect(described_class.for_scope(:runner)).to contain_exactly(
        HealthChecks::Checks::Runner::DeprecatedModel
      )
    end
  end

  describe ".local_for_scope" do
    it "registers the project-scope local checks" do
      expect(described_class.local_for_scope(:project)).to contain_exactly(
        HealthChecks::Checks::Project::AutoMergeWithoutOwner,
        HealthChecks::Checks::Project::ReviewWithoutBot,
        HealthChecks::Checks::Project::EmptyAllowlist,
        HealthChecks::Checks::Project::MissingGitHubCredential,
        HealthChecks::Checks::Project::SensitiveDataFreeModel
      )
    end

    it "skips network checks when listing local runner checks" do
      expect(described_class.local_for_scope(:runner)).to eq([])
    end
  end
end
