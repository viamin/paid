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

    it "registers the user-scope local checks" do
      expect(described_class.for_scope(:user)).to contain_exactly(
        HealthChecks::Checks::User::NoAgentRunners,
        HealthChecks::Checks::User::InvalidFallbackChain,
        HealthChecks::Checks::User::MissingDefaultRunner
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

    it "lists the user-scope local checks (all local)" do
      expect(described_class.local_for_scope(:user)).to contain_exactly(
        HealthChecks::Checks::User::NoAgentRunners,
        HealthChecks::Checks::User::InvalidFallbackChain,
        HealthChecks::Checks::User::MissingDefaultRunner
      )
    end
  end

  describe ".register" do
    it "adds a check class to the registry without duplicating it" do
      described_class.register(HealthChecks::Checks::Runner::DeprecatedModel)

      expect(described_class.for_scope(:runner)).to contain_exactly(
        HealthChecks::Checks::Runner::DeprecatedModel
      )
    end
  end
end
