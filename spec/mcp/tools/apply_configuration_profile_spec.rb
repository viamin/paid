# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ApplyConfigurationProfile do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  def call(profile_id:, overrides: {}, confirmed: true, user: owner)
    described_class.new(user:, session:).call(profile_id:, project_id: project.id, overrides:, confirmed:)
  end

  it "applies the profile in one confirmed batch" do
    result = call(profile_id: "observe_only", overrides: { active: false })

    expect(result).to include(
      profile_id: "observe_only",
      profile_name: "Observe Only",
      project_id: project.id,
      applied_overrides: { "active" => false }
    )
    expect(result[:applied_changes]).to include(include(key: "active", to: false, applied: true))
    expect(project.reload).to have_attributes(active: false, auto_pick_enabled: false)
    expect(project.adoption_mode).to eq("observe_only")
  end

  it "coerces boolean overrides before persisting JSON-backed settings" do
    result = call(profile_id: "solo_automated", overrides: { quality_gate_enabled: "true" })

    expect(result[:applied_overrides]).to eq({ "quality_gate_enabled" => true })
    expect(project.reload.quality_gate_settings["enabled"]).to be(true)
  end

  it "requires confirmation" do
    expect {
      call(profile_id: "observe_only", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  it "refuses to apply a blocked profile" do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(false)

    expect {
      call(profile_id: "team_reviewed", overrides: { owner_reviewer_login: "octocat" })
    }.to raise_error(Configuration::Profiles::BlockedError)
  end
end
