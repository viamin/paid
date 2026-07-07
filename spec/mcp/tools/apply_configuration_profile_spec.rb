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

  def expect_default_solo_profile_applied(result, default_branch:)
    expect(result[:applied]).to include(
      hash_including(level: :user, attribute: "user_settings.max_concurrent_runs", after: 5),
      hash_including(level: :tenant, attribute: "tenant_settings.max_concurrent_runs", after: 10)
    )
    expect(owner.settings.default_branch).to eq(default_branch)
    expect(owner.settings.max_concurrent_runs).to eq(5)
    expect(account.tenant_setting.max_concurrent_runs).to eq(10)
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

  it "rebuilds the plan from overrides when a stale serialized plan is supplied" do
    stale_plan = Tools::PlanConfigurationProfile.new(user: owner, session:).call(
      profile_id: "solo_fully_automated"
    )

    result = call(
      profile_id: "solo_fully_automated",
      overrides: { "max_concurrent_runs" => 7 },
      plan: stale_plan,
      confirmed: true
    )

    expect(result[:plan]).to include(profile_id: "solo_fully_automated")
    expect(result[:applied]).to include(
      hash_including(level: :user, attribute: "user_settings.max_concurrent_runs", after: 7),
      hash_including(level: :tenant, attribute: "tenant_settings.max_concurrent_runs", after: 7)
    )
    expect(owner.settings.max_concurrent_runs).to eq(7)
    expect(account.tenant_setting.max_concurrent_runs).to eq(7)
  end

  it "ignores caller-supplied plan changes and applies a server-built profile plan" do
    original_default_branch = owner.settings.default_branch
    forged_plan = {
      profile_id: "solo_fully_automated",
      changes: [
        {
          level: :user,
          attribute: "user_settings.default_branch",
          before: owner.settings.default_branch,
          after: "evil-branch"
        }
      ]
    }

    result = call(profile_id: "solo_fully_automated", plan: forged_plan, confirmed: true)

    expect(result[:plan][:changes]).not_to include(
      hash_including(attribute: "user_settings.default_branch", after: "evil-branch")
    )
    expect_default_solo_profile_applied(result, default_branch: original_default_branch)
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
