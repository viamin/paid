# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260612222959_make_create_pr_idle_timeout_seconds_nullable")

RSpec.describe MakeCreatePrIdleTimeoutSecondsNullable, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  include MigrationSpecHelpers

  around do |example|
    truncate_migration_test_data
    example.run
  ensure
    migration.migrate(:up)
    UserSetting.reset_column_information
    truncate_migration_test_data
  end

  it "nullifies legacy 360-second rows on up and restores them to 360 on down" do
    # Seed rows in the pre-up state by rolling back to down first.
    migration.migrate(:down)
    UserSetting.reset_column_information

    legacy_360_setting = create(:user_setting, create_pr_idle_timeout_seconds: 360)
    custom_420_setting = create(:user_setting, create_pr_idle_timeout_seconds: 420)

    migration.migrate(:up)
    UserSetting.reset_column_information

    expect(legacy_360_setting.reload.create_pr_idle_timeout_seconds).to be_nil
    expect(custom_420_setting.reload.create_pr_idle_timeout_seconds).to eq(420)
    expect(default_for(:create_pr_idle_timeout_seconds)).to be_nil
    expect(nullable?(:create_pr_idle_timeout_seconds)).to be(true)

    migration.migrate(:down)
    UserSetting.reset_column_information

    expect(legacy_360_setting.reload.create_pr_idle_timeout_seconds).to eq(360)
    expect(custom_420_setting.reload.create_pr_idle_timeout_seconds).to eq(420)
    expect(default_for(:create_pr_idle_timeout_seconds)).to eq(360)
    expect(nullable?(:create_pr_idle_timeout_seconds)).to be(false)
  end

  private

  def default_for(column_name)
    connection.columns(:user_settings).find { |c| c.name == column_name.to_s }&.default
  end

  def nullable?(column_name)
    connection.columns(:user_settings).find { |c| c.name == column_name.to_s }&.null
  end
end
