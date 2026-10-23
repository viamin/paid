# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-016
RSpec.describe Automation::PhaseSettings do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def settings
    described_class.call(project)
  end

  def configure(phases:, release: false, deployment: false)
    project.update!(
      described_class::SETTINGS_KEY => {
        described_class::PHASES_KEY => phases,
        described_class::RELEASE_KEY => release,
        described_class::DEPLOYMENT_KEY => deployment
      }
    )
  end

  describe "configured projects" do
    it "grants no standing authorization for a disabled phase" do
      configure(phases: { "coding" => true })

      expect(settings.phase_enabled?("coding")).to be(true)
      expect(settings.phase_enabled?("merge")).to be(false)
    end

    it "retains every subordinate capability value when a phase is turned off" do
      configure(phases: { "merge" => false })

      expect(settings.phase_enabled?("merge")).to be(false)
      expect(settings.to_h[described_class::PHASES_KEY]).to include("coding" => false, "discovery" => false)
    end

    it "never enables release or deployment implicitly from the phase switch" do
      configure(phases: { "release_deployment" => true })

      expect(settings.phase_enabled?("release_deployment")).to be(true)
      expect(settings.release_enabled?).to be(false)
      expect(settings.deployment_enabled?).to be(false)
    end

    it "keeps release and deployment independent of each other" do
      configure(phases: { "release_deployment" => true }, release: true, deployment: false)

      expect(settings.release_enabled?).to be(true)
      expect(settings.deployment_enabled?).to be(false)
    end
  end

  describe "projects without stored settings" do
    it "derives issue preparation from auto-enhance" do
      project.update!(auto_enhance_enabled: true, auto_pick_enabled: false, auto_scan_prs: false,
        auto_fix_merge_conflicts: false)

      expect(settings.phase_enabled?("issue_preparation")).to be(true)
      expect(settings.phase_enabled?("coding")).to be(false)
    end

    it "derives coding from any coding automation capability" do
      project.update!(auto_pick_enabled: true)

      expect(settings.phase_enabled?("coding")).to be(true)
      expect(settings.phase_enabled?("merge")).to be(false)
    end

    it "derives merge from auto-merge" do
      project.update!(auto_merge_mode: "all")

      expect(settings.phase_enabled?("merge")).to be(true)
    end

    it "derives release and deployment from release granularity" do
      project.update!(auto_release_granularity: "patch_only")

      expect(settings.phase_enabled?("release_deployment")).to be(true)
      expect(settings.release_enabled?).to be(true)
      expect(settings.deployment_enabled?).to be(false)
    end

    it "leaves project operations disabled because no capability exists yet" do
      expect(settings.phase_enabled?("operations")).to be(false)
    end
  end

  describe "automation phases settings update" do
    it "reports only phases that transitioned from disabled to enabled" do
      configure(phases: { "coding" => true, "merge" => false })

      result = described_class::Update.call(
        project: project,
        params: { "phases" => { "coding" => true, "merge" => true } }
      )

      expect(result.enabled_transitions).to eq(%w[merge])
    end

    it "treats saving an already-enabled phase as no transition" do
      configure(phases: { "coding" => true })

      result = described_class::Update.call(project: project, params: { "phases" => { "coding" => true } })

      expect(result.enabled_transitions).to be_empty
    end

    it "ignores unknown phase keys so they cannot widen authorization" do
      described_class::Update.call(project: project, params: { "phases" => { "not_a_phase" => true } })

      expect(settings.to_h[described_class::PHASES_KEY].keys).to match_array(Automation::Phases::ALL)
    end
  end
end