# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260514193654_increase_create_pr_idle_timeout_default")
require Rails.root.join("db/migrate/20260612222959_make_create_pr_idle_timeout_seconds_nullable")

RSpec.describe IncreaseCreatePrIdleTimeoutDefault, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:legacy_default_user_setting) { create(:user_setting, create_pr_idle_timeout_seconds: 300) }
  let(:custom_user_setting) { create(:user_setting, create_pr_idle_timeout_seconds: 420) }
  let(:preexisting_360_user_setting) { create(:user_setting, create_pr_idle_timeout_seconds: 360) }

  include MigrationSpecHelpers

  around do |example|
    truncate_migration_test_data
    example.run
  ensure
    migration.migrate(:up)
    # Re-apply the subsequent nullable migration so the column is left in the
    # correct fully-migrated state (nil default, nullable) regardless of test
    # execution order.
    MakeCreatePrIdleTimeoutSecondsNullable.new.migrate(:up)
    UserSetting.reset_column_information
    truncate_migration_test_data
  end

  it "backfills legacy 300-second rows on up without clobbering 360-second rows on down" do
    legacy_default_user_setting
    custom_user_setting
    preexisting_360_user_setting

    migration.migrate(:up)
    UserSetting.reset_column_information

    expect(legacy_default_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(custom_user_setting.reload.create_pr_idle_timeout_seconds).to eq(420)
    expect(preexisting_360_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(default_for(:create_pr_idle_timeout_seconds)).to eq(360)

    migration.migrate(:down)
    UserSetting.reset_column_information

    expect(legacy_default_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(custom_user_setting.reload.create_pr_idle_timeout_seconds).to eq(420)
    expect(preexisting_360_user_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(default_for(:create_pr_idle_timeout_seconds)).to eq(300)
  end

  private

  def default_for(column_name)
    connection.columns(:user_settings).find { |column| column.name == column_name.to_s }&.default
  end
end
