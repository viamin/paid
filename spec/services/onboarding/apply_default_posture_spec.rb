# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::ApplyDefaultPosture do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: actor) }

  before do
    Onboarding::StartOnboarding.call(account: account)
    Onboarding::CompleteStep.call(
      account: account,
      step: "first_project",
      metadata: { project_id: project.id }
    )
  end

  # @spec FEATURE-APPROVAL-004
  it "applies the proposed human-led posture to the first project when accepted" do
    result = described_class.call(
      account: account, actor: actor, choice: "human_led_feature_factory"
    )

    expect(result[:applied_changes].map { |change| change[:key] }).to include("operating_mode")
    expect(project.reload.operating_mode).to eq("human_led_feature_factory")
    expect(project.tdd_mode).to eq("non_strict")
    expect(project.auto_merge_mode).to eq("off")
  end

  # @spec FEATURE-APPROVAL-004
  it "does not apply anything when the standard posture is chosen" do
    result = described_class.call(account: account, actor: actor, choice: "standard")

    expect(result[:applied_changes]).to be_empty
    expect(project.reload.operating_mode).to eq("standard")
  end

  # @spec FEATURE-APPROVAL-003
  it "honors explicit auto-merge and TDD selections" do
    described_class.call(
      account: account,
      actor: actor,
      choice: "human_led_feature_factory",
      overrides: { "auto_merge_mode" => "dependabot_only", "tdd_mode" => "strict" }
    )

    expect(project.reload.auto_merge_mode).to eq("dependabot_only")
    expect(project.tdd_mode).to eq("strict")
  end

  it "records an audited configuration profile application" do
    expect {
      described_class.call(account: account, actor: actor, choice: "human_led_feature_factory")
    }.to change {
      account.account_activity_events.where(action: "configuration_profile.applied").count
    }.by(1)
  end

  it "is a no-op when onboarding has no first project" do
    account.onboarding_steps.find_by(step: "first_project").update!(metadata: {})
    project.destroy!

    result = described_class.call(account: account, actor: actor, choice: "human_led_feature_factory")

    expect(result[:applied_changes]).to be_empty
  end

  it "rejects unknown posture choices" do
    expect {
      described_class.call(account: account, actor: actor, choice: "chaos_factory")
    }.to raise_error(ArgumentError, /Unknown operating posture/)
  end
end
