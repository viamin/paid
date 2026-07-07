# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::PlanConfigurationProfile do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  it "returns a serialized configuration plan" do
    result = described_class.new(user: owner, session:).call(
      profile_id: "solo_fully_automated",
      overrides: { "max_concurrent_runs" => 7 }
    )

    expect(result[:profile_id]).to eq("solo_fully_automated")
    expect(result[:project_id]).to eq(project.id)
    expect(result[:changes]).to include(
      hash_including(level: :user, attribute: "user_settings.max_concurrent_runs", after: 7),
      hash_including(level: :tenant, attribute: "tenant_settings.max_concurrent_runs", after: 7)
    )
  end

  it "rejects non-hash overrides" do
    expect {
      described_class.new(user: owner, session:).call(profile_id: "solo_fully_automated", overrides: "nope")
    }.to raise_error(ArgumentError, /overrides must be an object/)
  end

  it "rejects inaccessible projects" do
    outsider = create(:user, :member, account: create(:account))

    expect {
      described_class.new(user: outsider, session: create(:chat_session, account: outsider.account, created_by: outsider)).call(
        profile_id: "solo_fully_automated",
        project_id: project.id
      )
    }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
