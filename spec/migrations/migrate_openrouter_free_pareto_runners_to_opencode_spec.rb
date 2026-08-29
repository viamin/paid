# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260828192834_migrate_openrouter_free_pareto_runners_to_opencode")

# @spec MODEL-POLICY-010 MODEL-POLICY-012
RSpec.describe MigrateOpenrouterFreeParetoRunnersToOpencode, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:user) { create(:user) }
  let(:provider_api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }

  include MigrationSpecHelpers

  around do |example|
    truncate_migration_test_data
    example.run
  ensure
    truncate_migration_test_data
  end

  def legacy_runner(runner_key:, name: "", tier_model_ids: nil, weight: 1, discarded_at: nil)
    described_class::MigrationRunner.create!(
      user_id: user.id,
      runner_key: runner_key,
      provider_key: runner_key,
      auth_type: "api_key",
      provider_api_key_id: provider_api_key.id,
      name: name,
      weight: weight,
      enabled_for_agent_runs: true,
      enabled_for_chat: true,
      enabled_for_fallback: true,
      fallback_role: "standard",
      config: {},
      tier_model_ids: tier_model_ids,
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  def opencode_runner(name:, fallback_role:, config:)
    described_class::MigrationRunner.create!(
      user_id: user.id, runner_key: "opencode", provider_key: "opencode", auth_type: "api_key",
      provider_api_key_id: provider_api_key.id, name: name, weight: 1,
      enabled_for_agent_runs: true, enabled_for_chat: true, enabled_for_fallback: true,
      fallback_role: fallback_role, config: config,
      created_at: Time.current, updated_at: Time.current
    )
  end

  def create_runner_state(runner_name:, metadata:)
    described_class::MigrationRunnerState.create!(
      user_id: user.id, runner_name: runner_name, circuit_state: "closed", failure_count: 0,
      metadata: metadata, created_at: Time.current, updated_at: Time.current
    )
  end

  it "migrates an openrouter_free row to opencode with model_policy free, preserving id/tier_model_ids/weight" do
    tier_ids = { "low" => "free/model-a", "mid" => "free/model-a", "high" => "free/model-b" }
    runner = legacy_runner(runner_key: "openrouter_free", tier_model_ids: tier_ids, weight: 5)

    migration.migrate(:up)

    reloaded = described_class::MigrationRunner.find(runner.id)
    expect(reloaded.runner_key).to eq("opencode")
    expect(reloaded.provider_key).to eq("opencode")
    expect(reloaded.config.dig("opencode", "model_policy")).to eq("free")
    expect(reloaded.tier_model_ids).to eq(tier_ids)
    expect(reloaded.weight).to eq(5)
    expect(reloaded.provider_api_key_id).to eq(provider_api_key.id)
  end

  it "migrates an openrouter_pareto row to opencode with the pareto model and specific policy" do
    tier_ids = { "low" => "openrouter/pareto-code", "mid" => "openrouter/pareto-code", "high" => "openrouter/pareto-code" }
    runner = legacy_runner(runner_key: "openrouter_pareto", tier_model_ids: tier_ids)

    migration.migrate(:up)

    reloaded = described_class::MigrationRunner.find(runner.id)
    expect(reloaded.runner_key).to eq("opencode")
    expect(reloaded.config.dig("opencode", "model")).to eq("openrouter/pareto-code")
    expect(reloaded.config.dig("opencode", "model_policy")).to eq("specific")
    expect(reloaded.tier_model_ids).to eq(tier_ids)
  end

  it "preserves the runner:<id> routing key across the rename" do
    runner = legacy_runner(runner_key: "openrouter_free")

    migration.migrate(:up)

    expect(described_class::MigrationRunner.find(runner.id).id).to eq(runner.id)
  end

  it "is idempotent — a second run makes no further changes" do
    runner = legacy_runner(runner_key: "openrouter_free")

    migration.migrate(:up)
    first_pass = described_class::MigrationRunner.find(runner.id).attributes

    migration.migrate(:up)
    second_pass = described_class::MigrationRunner.find(runner.id).attributes

    expect(second_pass).to eq(first_pass)
  end

  it "disambiguates the name when it would collide with an existing kept opencode row for the same key/user" do
    existing_opencode = described_class::MigrationRunner.create!(
      user_id: user.id, runner_key: "opencode", provider_key: "opencode", auth_type: "api_key",
      provider_api_key_id: provider_api_key.id, name: "", weight: 1,
      enabled_for_agent_runs: true, enabled_for_chat: true, enabled_for_fallback: true,
      fallback_role: "standard", config: { "opencode" => { "model" => "openrouter/some-model" } },
      created_at: Time.current, updated_at: Time.current
    )
    legacy = legacy_runner(runner_key: "openrouter_free", name: "")

    migration.migrate(:up)

    reloaded_legacy = described_class::MigrationRunner.find(legacy.id)
    expect(reloaded_legacy.name).not_to eq(existing_opencode.reload.name)
    expect(reloaded_legacy.name).to include("openrouter_free").or include("#{legacy.id}")
  end

  it "rekeys a bare-key RunnerState onto the surviving runner's routing key" do
    runner = legacy_runner(runner_key: "openrouter_free")
    state = described_class::MigrationRunnerState.create!(
      user_id: user.id,
      runner_name: "openrouter_free",
      circuit_state: "closed",
      failure_count: 0,
      metadata: { "preferred_tier_model_ids" => { "low" => "free/model-a" } },
      created_at: Time.current,
      updated_at: Time.current
    )

    migration.migrate(:up)

    expect(described_class::MigrationRunnerState.exists?(user_id: user.id, runner_name: "openrouter_free")).to be false
    rekeyed = described_class::MigrationRunnerState.find(state.id)
    expect(rekeyed.runner_name).to eq("runner:#{runner.id}")
    expect(rekeyed.metadata["preferred_tier_model_ids"]).to eq({ "low" => "free/model-a" })
  end

  it "merges legacy RunnerState metadata into an existing routing-key row without dropping either" do
    runner = legacy_runner(runner_key: "openrouter_free")
    described_class::MigrationRunnerState.create!(
      user_id: user.id, runner_name: "openrouter_free", circuit_state: "closed", failure_count: 0,
      metadata: { "rate_limited_models" => { "free/model-a" => 1.hour.from_now.iso8601 } },
      created_at: Time.current, updated_at: Time.current
    )
    described_class::MigrationRunnerState.create!(
      user_id: user.id, runner_name: "runner:#{runner.id}", circuit_state: "closed", failure_count: 2,
      metadata: { "quota_status" => { "available" => true } },
      created_at: Time.current, updated_at: Time.current
    )

    migration.migrate(:up)

    merged = described_class::MigrationRunnerState.find_by(user_id: user.id, runner_name: "runner:#{runner.id}")
    expect(merged.failure_count).to eq(2)
    expect(merged.metadata["quota_status"]).to eq({ "available" => true })
    expect(merged.metadata["rate_limited_models"]).to be_present
    expect(described_class::MigrationRunnerState.exists?(runner_name: "openrouter_free", user_id: user.id)).to be false
  end

  it "rekeys an existing bare opencode RunnerState when exactly one kept free-policy opencode runner owns it" do # @spec MODEL-POLICY-012
    runner = opencode_runner(
      name: "OpenCode Free",
      fallback_role: "rate_limit_fallback",
      config: { "opencode" => { "model_policy" => "free" } }
    )
    create_runner_state(
      runner_name: "opencode",
      metadata: {
        "preferred_tier_model_ids" => { "mid" => "free/model-a" },
        "rate_limited_models" => { "free/model-a" => 1.hour.from_now.iso8601 }
      }
    )

    migration.migrate(:up)

    migrated = described_class::MigrationRunnerState.find_by!(user_id: user.id, runner_name: "runner:#{runner.id}")
    expect(migrated.metadata["preferred_tier_model_ids"]).to eq({ "mid" => "free/model-a" })
    expect(migrated.metadata["rate_limited_models"]).to be_present
    expect(described_class::MigrationRunnerState.exists?(user_id: user.id, runner_name: "opencode")).to be(false)
  end

  it "leaves a bare opencode RunnerState in place when kept specific-model opencode runners make ownership ambiguous" do # @spec MODEL-POLICY-012
    opencode_runner(
      name: "OpenCode Free",
      fallback_role: "rate_limit_fallback",
      config: { "opencode" => { "model_policy" => "free" } }
    )
    opencode_runner(
      name: "OpenCode Specific",
      fallback_role: "standard",
      config: { "opencode" => { "model_policy" => "specific", "model" => "openrouter/pareto-code" } }
    )
    create_runner_state(runner_name: "opencode", metadata: { "preferred_tier_model_ids" => { "mid" => "free/model-a" } })

    migration.migrate(:up)

    expect(described_class::MigrationRunnerState.exists?(user_id: user.id, runner_name: "opencode")).to be(true)
  end

  it "does not touch runners that are not the legacy runner keys" do
    other = create(:runner, user: user, runner_key: "cursor", auth_type: "subscription")

    migration.migrate(:up)

    expect(other.reload.runner_key).to eq("cursor")
  end

  it "remaps legacy agent_type/final_runner values on agent_runs so parked/queued legacy runs stay claimable" do # @spec MODEL-POLICY-010
    project = create(:project)
    run = create(:agent_run, project: project, agent_type: "claude_code", status: "queued")
    ActiveRecord::Base.connection.execute(<<~SQL)
      UPDATE agent_runs SET agent_type = 'openrouter_pareto', final_runner = 'openrouter_free' WHERE id = #{run.id}
    SQL

    migration.migrate(:up)

    reloaded = AgentRun.find(run.id)
    expect(reloaded.agent_type).to eq("opencode")
    expect(reloaded.final_runner).to eq("opencode")
  end

  it "rekeys runner_key and lookup_key on resource profiles so learned tuning keeps matching" do # @spec MODEL-POLICY-010
    profile = create(:agent_run_resource_profile, runner_key: "openrouter_pareto", goal: "create_pr")

    migration.migrate(:up)

    reloaded = profile.reload
    expect(reloaded.runner_key).to eq("opencode")
    expect(reloaded.lookup_key).to eq(
      AgentRunResourceProfile.lookup_key_for(
        profile_level: "specific",
        account_id: profile.account_id,
        project_id: profile.project_id,
        runner_key: "opencode",
        goal: "create_pr"
      )
    )
  end

  it "skips rekeying a resource profile that would collide with an existing opencode profile at the same scope" do # @spec MODEL-POLICY-010
    legacy_profile = create(:agent_run_resource_profile, runner_key: "openrouter_free", goal: "create_pr")
    colliding_opencode_profile = create(
      :agent_run_resource_profile,
      account: legacy_profile.account, project: legacy_profile.project,
      runner_key: "opencode", goal: "create_pr"
    )

    migration.migrate(:up)

    expect(legacy_profile.reload.runner_key).to eq("openrouter_free")
    expect(colliding_opencode_profile.reload.runner_key).to eq("opencode")
  end

  it "does not touch resource profiles for other runner keys" do
    other_profile = create(:agent_run_resource_profile, runner_key: "claude")

    migration.migrate(:up)

    expect(other_profile.reload.runner_key).to eq("claude")
  end
end
