# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ApplyConfigurationProfile do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner) }

  before { create(:github_installation, account:) }

  def call(user: owner, **args)
    described_class.new(user:, session:).call(**args)
  end

  it "requires confirmation" do
    expect {
      call(profile_id: "solo_fully_automated", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  it "applies the profile and returns the serialized plan" do
    result = call(
      profile_id: "solo_fully_automated",
      overrides: { "max_concurrent_runs" => 7 },
      confirmed: true
    )

    expect(result[:applied]).to include(
      hash_including(level: :user, attribute: "user_settings.max_concurrent_runs", after: 7),
      hash_including(level: :tenant, attribute: "tenant_settings.max_concurrent_runs", after: 7)
    )
    expect(result[:plan]).to include(profile_id: "solo_fully_automated")
    expect(owner.settings.max_concurrent_runs).to eq(7)
    expect(account.tenant_setting.max_concurrent_runs).to eq(7)
  end

  it "accepts a previously planned serialized plan payload" do
    plan = Tools::PlanConfigurationProfile.new(user: owner, session:).call(
      profile_id: "solo_fully_automated",
      overrides: { "max_concurrent_runs" => 6 }
    )

    result = call(profile_id: "solo_fully_automated", plan:, confirmed: true)

    expect(result[:plan]).to include(profile_id: "solo_fully_automated")
    expect(owner.settings.max_concurrent_runs).to eq(6)
  end

  it "reports unmet prerequisites as a blocked result" do
    account.github_installations.delete_all

    result = call(profile_id: "solo_fully_automated", confirmed: true)

    expect(result).to include(status: "blocked", error: "unmet_prerequisites")
    expect(result[:prerequisites]).to include(hash_including(key: "github_app_installed"))
  end

  it "skips unauthorized tenant-level changes while still applying authorized user-level changes" do
    member = create(:user, :member, account:)

    result = call(user: member, profile_id: "solo_fully_automated", confirmed: true)

    expect(result[:applied]).to include(hash_including(level: :user))
    expect(result[:skipped]).to include(hash_including(level: :tenant, reason: "unauthorized"))
    expect(member.settings.reload.run_concurrency_mode).to eq("auto")
  end
end
