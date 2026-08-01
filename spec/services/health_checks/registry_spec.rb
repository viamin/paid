# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Registry do
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

    it "registers the runner-scope local checks" do
      expect(described_class.local_for_scope(:runner)).to contain_exactly(
        HealthChecks::Checks::Runner::InactiveModel,
        HealthChecks::Checks::Runner::ExpiredModel,
        HealthChecks::Checks::Runner::BelowQualityBarModel,
        HealthChecks::Checks::Runner::IncompatibleModel,
        HealthChecks::Checks::Runner::MissingRunnerCredentials,
        HealthChecks::Checks::Runner::SupersededModel
      )
    end

    it "registers the user-scope local checks" do
      expect(described_class.local_for_scope(:user)).to contain_exactly(
        HealthChecks::Checks::User::NoAgentRunners,
        HealthChecks::Checks::User::InvalidFallbackChain,
        HealthChecks::Checks::User::MissingDefaultRunner
      )
    end
  end
end
