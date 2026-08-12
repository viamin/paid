# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260812124601_add_runner_handle_to_execution_tables")

RSpec.describe AddRunnerHandleToExecutionTables, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:run_class) { Class.new(ActiveRecord::Base) { self.table_name = "agent_runs" } }
  let(:test_runs) { [] }

  around do |example|
    example.run
  ensure
    # Ensure the migration is in the up state regardless of test outcome so
    # the runner_handle column exists for the rest of the suite.
    migration.migrate(:up)
    run_class.reset_column_information
    AgentRun.reset_column_information
    test_runs.each { |run| run_class.where(id: run.id).delete_all }
  end

  def create_test_run(container_id:, container_host: nil)
    run = create(:agent_run, container_id: container_id, container_host: container_host)
    test_runs << run
    run
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
end
