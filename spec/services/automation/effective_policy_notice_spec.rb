# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-010 @spec AUTOMATION-PHASES-016
RSpec.describe Automation::EffectivePolicyNotice do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def configure(phases:, release: false, deployment: false)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => phases,
        Automation::PhaseSettings::RELEASE_KEY => release,
        Automation::PhaseSettings::DEPLOYMENT_KEY => deployment
      }
    )
  end

  def notice(endpoint:, continuation: false)
    described_class.new(project:, phase: "coding", endpoint:, continuation_selected: continuation)
  end

  it "explains that later project automation may continue and names the responsible settings" do
    configure(phases: { "coding" => true, "merge" => true })

    summary = notice(endpoint: "coding").summary

    expect(summary).to include("You selected automation through Coding.")
    expect(summary).to include("Merge")
    expect(summary).to include("this project's Merge phase setting")
  end

  it "describes continuation as conditional authorization rather than a guarantee" do
    configure(phases: { "coding" => true, "merge" => true })

    expect(notice(endpoint: "coding").summary).to include("conditional authorization, not a guarantee")
  end

  it "requires no notice when nothing follows the selected endpoint" do
    configure(phases: { "coding" => true, "merge" => false })

    expect(notice(endpoint: "coding")).not_to be_required
    expect(notice(endpoint: "coding").summary).to include("Paid stops after the action you selected")
  end

  it "applies the notice even when continuation is unchecked but project policy permits follow-ups" do
    configure(phases: { "coding" => true, "merge" => true })

    expect(notice(endpoint: "coding", continuation: false)).to be_required
  end

  it "updates its signature when the policy changes" do
    configure(phases: { "coding" => true, "merge" => false })
    before_signature = notice(endpoint: "coding").signature

    configure(phases: { "coding" => true, "merge" => true })

    expect(notice(endpoint: "coding").signature).not_to eq(before_signature)
  end

  it "does not change with the user's endpoint or continuation selection" do
    configure(phases: { "coding" => true, "merge" => true })

    signature = notice(endpoint: "coding", continuation: false).signature

    expect(notice(endpoint: "merge", continuation: true).signature).to eq(signature)
  end

  describe "release and deployment" do
    it "names the release control when only releases are enabled" do
      configure(phases: { "merge" => true, "release_deployment" => true }, release: true)

      expect(notice(endpoint: "merge").summary).to include("this project's release control")
    end

    it "names the deployment control when only deployments are enabled" do
      configure(phases: { "merge" => true, "release_deployment" => true }, deployment: true)

      expect(notice(endpoint: "merge").summary).to include("this project's deployment control")
    end

    it "does not warn about release or deployment when their controls are off" do
      configure(phases: { "merge" => true, "release_deployment" => true })

      expect(notice(endpoint: "merge")).not_to be_required
    end
  end
end
