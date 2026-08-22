# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260812124601_add_runner_handle_to_execution_tables")

RSpec.describe AddRunnerHandleToExecutionTables, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:run_class) { Class.new(ActiveRecord::Base) { self.table_name = "agent_runs" } }

  around do |example|
    truncate_agent_run_data
    example.run
  ensure
    # Ensure the migration is in the up state regardless of test outcome so
    # the runner_handle column exists for the rest of the suite.
    migration.migrate(:up)
    run_class.reset_column_information
    AgentRun.reset_column_information
    truncate_agent_run_data
  end

  def create_test_run(container_id:, container_host: nil)
    create(:agent_run, container_id: container_id, container_host: container_host)
  end

  it "backfills runner_handle from existing container_id and container_host on up" do
    run_with_container = create_test_run(container_id: "backfill-test-1", container_host: "remote-host")
    run_without_container = create_test_run(container_id: nil)

    migration.migrate(:down)
    run_class.reset_column_information

    expect(run_class.columns.map(&:name)).not_to include("runner_handle")

    migration.migrate(:up)
    run_class.reset_column_information

    reloaded_with = run_class.find(run_with_container.id)
    handle = reloaded_with.runner_handle
    expect(handle).not_to be_nil
    expect(handle["runner_type"]).to eq("local_docker")
    expect(handle["identifier"]).to eq("backfill-test-1")
    expect(handle["host"]).to eq("remote-host")
    expect(handle["workspace_ref"]).to eq("paid-workspace-#{run_with_container.id}")
    expect(handle["metadata"]).to eq({ "agent_run_id" => run_with_container.id,
                                       "worktree_path" => run_with_container.worktree_path })

    reloaded_without = run_class.find(run_without_container.id)
    expect(reloaded_without.runner_handle).to be_nil
  end

  it "adds and removes the runner_handle column on all three tables" do
    migration.migrate(:down)

    expect(connection.column_exists?(:agent_runs, :runner_handle)).to be(false)
    expect(connection.column_exists?(:container_pool_entries, :runner_handle)).to be(false)
    expect(connection.column_exists?(:service_containers, :runner_handle)).to be(false)

    migration.migrate(:up)

    expect(connection.column_exists?(:agent_runs, :runner_handle)).to be(true)
    expect(connection.column_exists?(:container_pool_entries, :runner_handle)).to be(true)
    expect(connection.column_exists?(:service_containers, :runner_handle)).to be(true)
  end

  private

  # Deletes the full graph of records the +agent_run+ factory creates (runs,
  # their issues and projects, and the account/runners backing them) so the
  # non-transactional spec leaves the shared test database clean for later
  # migration specs. Deletion order respects foreign keys (children first).
  def truncate_agent_run_data
    connection.execute("DELETE FROM agent_run_logs")
    connection.execute("DELETE FROM provisioning_intents")
    connection.execute("DELETE FROM agent_runs")
    connection.execute("DELETE FROM project_service_containers")
    connection.execute("DELETE FROM service_container_metrics")
    connection.execute("DELETE FROM service_containers")
    connection.execute("DELETE FROM issues")
    connection.execute("DELETE FROM projects")
    connection.execute("DELETE FROM runners")
    connection.execute("DELETE FROM runner_states")
    connection.execute("DELETE FROM github_tokens")
    connection.execute("DELETE FROM user_settings")
    connection.execute("DELETE FROM tenant_settings")
    connection.execute("DELETE FROM account_memberships")
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM accounts")
  end
end
