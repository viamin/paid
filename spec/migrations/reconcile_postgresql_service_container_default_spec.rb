# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261020200635_reconcile_postgresql_service_container_default")

RSpec.describe ReconcilePostgresqlServiceContainerDefault, :aggregate_failures do
  self.use_transactional_tests = false

  include MigrationSpecHelpers

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:old_default) { [ "postgres:16.13", "redis:7-alpine", "selenium/standalone-chromium:latest" ] }
  let(:new_default) { [ "postgres:16.15", "redis:7-alpine", "selenium/standalone-chromium:latest" ] }

  around do |example|
    truncate_migration_test_data
    example.run
  ensure
    migration.migrate(:up)
    UserSetting.reset_column_information
    truncate_migration_test_data
  end

  # @spec TOOLCHAIN-PIN-025
  it "updates only the exact previous allowlist default and preserves service containers" do
    unchanged_setting = create(:user_setting, allowed_service_images: old_default)
    overridden_setting = create(:user_setting, allowed_service_images: old_default + [ "custom:1" ])
    service = build(:service_container, image: "postgres:16.13", status: "running", docker_container_id: "persisted")
    service.save!(validate: false)

    migration.migrate(:up)
    UserSetting.reset_column_information

    expect(unchanged_setting.reload.allowed_service_images).to eq(new_default)
    expect(overridden_setting.reload.allowed_service_images).to eq(old_default + [ "custom:1" ])
    expect(service.reload).to have_attributes(image: "postgres:16.13", status: "running", docker_container_id: "persisted")
    expect(JSON.parse(default_for(:user_settings, :allowed_service_images))).to eq(new_default)
  end

  private

  def default_for(table_name, column_name)
    connection.columns(table_name).find { |column| column.name == column_name.to_s }&.default
  end
end
