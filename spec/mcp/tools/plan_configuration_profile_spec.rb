# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::PlanConfigurationProfile do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  def call(profile_id:, overrides: {}, user: owner)
    described_class.new(user:, session:).call(profile_id:, project_id: project.id, overrides:)
  end

  it "returns a deterministic plan for a curated profile" do
    result = call(profile_id: "observe_only")

    expect(result).to include(
      profile_id: "observe_only",
      profile_name: "Observe Only",
      project_id: project.id,
      blocked: false
    )
    expect(result[:changes]).to all(include(:key, :from, :to))
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
end
