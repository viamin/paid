# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260826192816_backfill_execution_usage_from_infrastructure_spend_stamp")

# @spec EXEC-USAGE-010
RSpec.describe BackfillExecutionUsageFromInfrastructureSpendStamp, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  include MigrationSpecHelpers

  around do |example|
    truncate_agent_run_tables
    truncate_migration_test_data
    example.run
  ensure
    truncate_agent_run_tables
    truncate_migration_test_data
  end

  # MigrationSpecHelpers#truncate_migration_test_data truncates projects
  # without first clearing rows that reference it (agent_runs, issues) or
  # each other (execution_usages -> agent_runs, execution_resources ->
  # agent_runs), which this spec creates.
  def truncate_agent_run_tables
    connection = ActiveRecord::Base.connection
    %w[execution_usages execution_resources agent_runs issues].each { |table| connection.execute("DELETE FROM #{table}") }
  end

  def stamped_run(status_trait, rate_cents_per_hour: 120, requested_resources: nil)
    metadata = {
      "infrastructure_spend" => { "rate_cents_per_hour" => rate_cents_per_hour },
      "planned_container_host" => "local"
    }
    metadata["requested_resources"] = requested_resources if requested_resources

    create(:agent_run, status_trait,
      project: project,
      provisioning_started_at: 2.hours.ago,
      external_metadata: metadata)
  end

  it "backfills an ExecutionUsage row using the stamped rate, not a re-resolved one" do
    run = stamped_run(:completed, rate_cents_per_hour: 120,
      requested_resources: { "cpu_quota" => 200_000, "memory_bytes" => 4.gigabytes, "disk_bytes" => 40.gigabytes })

    migration.migrate(:up)

    usage = run.reload.execution_usage
    expect(usage).to be_present
    expect(usage.runner_backend).to eq("local")
    expect(usage.rate_cents_per_hour).to eq(120)
    expect(usage.billed_duration_seconds).to eq((run.completed_at - run.provisioning_started_at).to_i)
    expect(usage.infra_cost_cents).to eq(((120 * usage.billed_duration_seconds) / 3600.0).round)
    expect(usage.requested_cpu_cores).to eq(2.0)
    expect(usage.requested_memory_mib).to eq(4096)
    expect(usage.requested_disk_gb).to eq(40)
    expect(usage.termination_reason).to eq("completed")
  end

  it "denormalizes the backfilled cost onto the AgentRun row" do
    run = stamped_run(:failed, rate_cents_per_hour: 60)

    migration.migrate(:up)

    run.reload
    expect(run.runner_backend).to eq("local")
    expect(run.infra_cost_cents).to eq(run.execution_usage.infra_cost_cents)
    expect(run.billed_duration_seconds).to eq(run.execution_usage.billed_duration_seconds)
  end

  it "maps status to the matching termination_reason" do
    cancelled = stamped_run(:cancelled)
    timed_out = stamped_run(:timeout)

    migration.migrate(:up)

    expect(cancelled.reload.execution_usage.termination_reason).to eq("cancelled")
    expect(timed_out.reload.execution_usage.termination_reason).to eq("timed_out")
  end

  it "does not create a row for a run with no stamped rate" do
    run = create(:agent_run, :completed, project: project, provisioning_started_at: 2.hours.ago,
      external_metadata: {})

    migration.migrate(:up)

    expect(run.reload.execution_usage).to be_nil
  end

  it "backfills a run whose stamped rate is explicitly zero" do
    run = stamped_run(:completed, rate_cents_per_hour: 0)

    migration.migrate(:up)

    usage = run.reload.execution_usage
    expect(usage).to be_present
    expect(usage.rate_cents_per_hour).to eq(0)
    expect(usage.infra_cost_cents).to eq(0)
    expect(run.infra_cost_cents).to eq(0)
    expect(run.billed_duration_seconds).to eq(usage.billed_duration_seconds)
  end

  # @spec EXEC-USAGE-007
  it "does not create a row for a run whose container is currently retained" do
    run = stamped_run(:completed)
    run.update!(container_retained_until: 2.hours.from_now)

    migration.migrate(:up)

    expect(run.reload.execution_usage).to be_nil
  end

  # @spec EXEC-USAGE-007
  it "does not create a row for a run whose environment resource is still live or cleanup-pending" do
    active_run = stamped_run(:completed)
    cleanup_pending_run = stamped_run(:completed)
    create(:execution_resource, agent_run: active_run, project: project, account: account, state: "active")
    create(:execution_resource, agent_run: cleanup_pending_run, project: project, account: account,
      state: "cleanup_pending")

    migration.migrate(:up)

    expect(active_run.reload.execution_usage).to be_nil
    expect(cleanup_pending_run.reload.execution_usage).to be_nil
  end

  it "backfills a run whose environment resource was cleaned and whose retention ttl expired" do
    cleaned_run = stamped_run(:completed)
    expired_retention_run = stamped_run(:completed)
    create(:execution_resource, agent_run: cleaned_run, project: project, account: account, state: "cleaned")
    expired_retention_run.update!(container_retained_until: 1.hour.ago)

    migration.migrate(:up)

    expect(cleaned_run.reload.execution_usage).to be_present
    expect(expired_retention_run.reload.execution_usage).to be_present
  end

  it "does not duplicate a run that already has an ExecutionUsage row" do
    run = stamped_run(:completed)
    create(:execution_usage, agent_run: run, runner_backend: "existing",
      provisioned_at: run.provisioning_started_at, terminated_at: run.completed_at,
      termination_reason: "completed", infra_cost_cents: 999, rate_cents_per_hour: 999)

    migration.migrate(:up)

    expect(ExecutionUsage.where(agent_run_id: run.id).count).to eq(1)
    expect(run.reload.execution_usage.runner_backend).to eq("existing")
  end

  it "re-applies tenant bypass for each batch cycle, including the final empty scan" do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    3.times { stamped_run(:completed) }
    allow(migration).to receive(:execute).and_call_original

    migration.migrate(:up)

    expect(migration).to have_received(:execute)
      .with("SET LOCAL paid.bypass_tenant_rls = 'true'")
      .exactly(3).times
  end
end
