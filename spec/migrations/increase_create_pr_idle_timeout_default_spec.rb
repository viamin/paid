# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260514193654_increase_create_pr_idle_timeout_default")

RSpec.describe IncreaseCreatePrIdleTimeoutDefault, :aggregate_failures do
  let(:migration) { described_class.new }
  let(:legacy_default_user_setting) { create(:user_setting, create_pr_idle_timeout_seconds: 300) }
  let(:custom_user_setting) { create(:user_setting, create_pr_idle_timeout_seconds: 420) }
  let(:preexisting_360_user_setting) { create(:user_setting, create_pr_idle_timeout_seconds: 360) }

  it "backfills legacy 300-second rows on up without clobbering 360-second rows on down" do
    legacy_default_user_setting
    custom_user_setting
    preexisting_360_user_setting

    migration.migrate(:up)

    expect(legacy_default_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(custom_user_setting.reload.create_pr_idle_timeout_seconds).to eq(420)
    expect(preexisting_360_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(UserSetting.column_defaults["create_pr_idle_timeout_seconds"]).to eq(360)

    migration.migrate(:down)

    expect(legacy_default_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(custom_user_setting.reload.create_pr_idle_timeout_seconds).to eq(420)
    expect(preexisting_360_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(UserSetting.column_defaults["create_pr_idle_timeout_seconds"]).to eq(300)
  end
end
