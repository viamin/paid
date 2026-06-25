# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260625062207_adjust_default_agent_run_timeouts")

RSpec.describe AdjustDefaultAgentRunTimeouts, :aggregate_failures do
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
    Project.reset_column_information
    truncate_migration_test_data
  end

  it "updates untouched defaults without clobbering explicit 3600-second user or project preferences" do
    migration.migrate(:down)
    UserSetting.reset_column_information
    Project.reset_column_information

    untouched_setting = create(:user_setting, agent_timeout_seconds: 3600)
    explicit_3600_setting = create(:user_setting, agent_timeout_seconds: 3600)
    explicit_3600_setting.update!(default_poll_interval_seconds: 120)
    project_default = create(:project, max_execution_seconds: 3600)
    explicit_3600_project = create(:project, max_execution_seconds: 3600)
    explicit_3600_project.update!(poll_interval_seconds: 120)

    migration.migrate(:up)
    UserSetting.reset_column_information
    Project.reset_column_information

    expect(untouched_setting.reload.agent_timeout_seconds).to eq(5400)
    expect(explicit_3600_setting.reload.agent_timeout_seconds).to eq(3600)
    expect(project_default.reload.max_execution_seconds).to eq(7200)
    expect(explicit_3600_project.reload.max_execution_seconds).to eq(3600)
    expect(default_for(:user_settings, :agent_timeout_seconds)).to eq(5400)
    expect(default_for(:projects, :max_execution_seconds)).to eq(7200)
  end

  private

  def default_for(table_name, column_name)
    connection.columns(table_name).find { |column| column.name == column_name.to_s }&.default
  end
end
