# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260824021817_create_page_load_measurements")
require Rails.root.join("db/migrate/20260824021819_create_page_load_regression_findings")

RSpec.describe CreatePageLoadMeasurements, :aggregate_failures do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:measurements_migration) { described_class.new }
  let(:findings_migration) { CreatePageLoadRegressionFindings.new }

  around do |example|
    ActiveRecord::Migration.suppress_messages do
      teardown!
      example.run
    ensure
      teardown!
      measurements_migration.up
      findings_migration.up
      reset_column_information!
    end
  end

  before do
    ActiveRecord::Migration.suppress_messages do
      measurements_migration.up
      findings_migration.up
      reset_column_information!
    end
  end

  # @spec PAGE-LOAD-LEDGER-002
  it "forces tenant row-level security on the page load tables" do
    %w[page_load_measurements page_load_regression_findings].each do |table|
      expect(tenant_policy_present?(table)).to be(true)
      expect(row_level_security_enabled?(table)).to be(true)
      expect(row_level_security_forced?(table)).to be(true)
      expect(policy_qual(table)).to include("account_id = paid_current_account_id()")
    end
  end

  # @spec PAGE-LOAD-LEDGER-003
  it "keeps one measurement per capture and route" do
    expect(connection.index_exists?(:page_load_measurements,
      [ :project_id, :pull_request_number, :commit_sha, :route_name ], unique: true)).to be(true)
  end

  # @spec PAGE-LOAD-REGRESSION-009
  it "keeps one open finding per pull request and route" do
    index = connection.indexes(:page_load_regression_findings)
      .find { |i| i.name == "idx_page_load_findings_one_open_per_route" }

    expect(index.unique).to be(true)
    expect(index.where).to include("open")
  end

  private

  def teardown!
    findings_migration.down if connection.table_exists?(:page_load_regression_findings)
    measurements_migration.down if connection.table_exists?(:page_load_measurements)
    reset_column_information!
  end

  def reset_column_information!
    PageLoadMeasurement.reset_column_information
    PageLoadRegressionFinding.reset_column_information
  end

  def tenant_policy_present?(table)
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM pg_policies
      WHERE schemaname = 'public' AND tablename = '#{table}' AND policyname = 'tenant_isolation'
    SQL
  end

  def policy_qual(table)
    connection.select_value(<<~SQL.squish).to_s
      SELECT qual FROM pg_policies
      WHERE schemaname = 'public' AND tablename = '#{table}' AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?(table)
    truthy?(connection.select_value("SELECT relrowsecurity FROM pg_class WHERE relname = '#{table}'"))
  end

  def row_level_security_forced?(table)
    truthy?(connection.select_value("SELECT relforcerowsecurity FROM pg_class WHERE relname = '#{table}'"))
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
