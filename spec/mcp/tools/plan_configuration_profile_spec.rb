# frozen_string_literal: true

require "rails_helper"

# @spec CONFIG-PROFILES-003
RSpec.describe Tools::PlanConfigurationProfile do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  before do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  def call(profile_id:, overrides: {}, user: owner)
    described_class.new(user:, session:).call(profile_id:, project_id: project.id, overrides:)
  end

  it "returns a deterministic plan for a curated profile" do
    result = call(profile_id: "observe_only")

    expect(result).to include(
      profile_id: "observe_only",
      profile_name: "Observe Only",
      project_id: project.id,
      blocked: false,
      skipped_levels: []
    )
    expect(result[:changes]).to all(include(:key, :from, :to, :level))
  end

  it "accepts bounded overrides declared by the profile" do
    result = call(profile_id: "observe_only", overrides: { active: false })

    expect(result[:applied_overrides]).to eq({ "active" => false })
    expect(result[:changes]).to include(include(key: "active", to: false))
  end

  it "coerces boolean overrides before diffing and returning the plan payload" do
    project.update!(active: false)

    result = call(profile_id: "observe_only", overrides: { active: "false" })

    expect(result[:applied_overrides]).to eq({ "active" => false })
    expect(result[:changes]).not_to include(include(key: "active"))
  end

  it "rejects undeclared overrides" do
    expect {
      call(profile_id: "observe_only", overrides: { owner_reviewer_login: "octocat" })
    }.to raise_error(Configuration::Profiles::UnknownOverrideError)
  end

  it "rejects invalid boolean overrides" do
    expect {
      call(profile_id: "observe_only", overrides: { active: "no" })
    }.to raise_error(ArgumentError, /Invalid boolean override/)
  end

  it "reports skipped levels for callers who cannot update every target" do
    member = create(:user, :member, account:)
    member.settings.update!(run_concurrency_mode: "auto")
    member_session = create(:chat_session, account:, created_by: member, project:)

    result = described_class.new(user: member, session: member_session).call(profile_id: "observe_only", project_id: project.id, overrides: {})

    expect(result[:skipped_levels]).to contain_exactly(
      include("level" => "project", "reason" => "Not authorized to update project settings"),
      include("level" => "tenant", "reason" => "Not authorized to update tenant settings")
    )
  end
end
