# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::PostureDescriber do
  before do
    # Some built-in postures enable paid-agent review; treat the underlying
    # GitHub App credential as an external dependency in specs.
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end
  describe ".describe_current_posture" do
    it "reports an exact match when the project matches a profile" do
      profile = ConfigurationProfiles::Registry.find(:observe_only)
      project = build_project_for(profile)

      result = described_class.describe_current_posture(project)

      expect(result.exact?).to be true
      expect(result.match_kind).to eq(:exact)
      expect(result.profile.key).to eq(:observe_only)
      expect(result.differences).to be_empty
      expect(result.summary).to eq("Observe Only (exact match)")
    end

    it "reports the nearest profile with the differing fields" do
      profile = ConfigurationProfiles::Registry.find(:solo_automated)
      project = build_project_for(profile)

      # Flip one lever away from solo_automated.
      ConfigurationProfiles::FieldSet.write(project, :auto_pick_enabled, false)

      result = described_class.describe(project)

      expect(result.exact?).to be false
      expect(result.match_kind).to eq(:nearest)
      expect(result.profile.key).to eq(:solo_automated)
      expect(result.differences.map(&:field)).to include(:auto_pick_enabled)
      expect(result.matching_fields).to eq(result.total_fields - result.differences.length)
    end

    it "always returns the closest profile even when far from any preset" do
      project = create(:project)
      result = described_class.describe(project)

      expect(result.profile).to be_a(ConfigurationProfiles::Profile)
      expect(result.total_fields).to be_positive
    end
  end

  # Helper: persist a project whose settings match the given profile, by
  # applying the profile through the real applier so nested settings are
  # written exactly as production would write them.
  def build_project_for(profile)
    project = create(:project)
    plan = ConfigurationProfiles::Planner.for_profile(project, profile)
    ConfigurationProfiles::Applier.call(project, plan)
    project.reload
  end
end
