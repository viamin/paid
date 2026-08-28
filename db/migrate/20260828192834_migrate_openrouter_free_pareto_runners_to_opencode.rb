# frozen_string_literal: true

# @spec MODEL-POLICY-010 MODEL-POLICY-012
# RDR-065 (#3671): folds the legacy openrouter_free / openrouter_pareto
# pseudo-keys into the opencode runner they always dispatched through
# (RunnerSupport::APP_RUNNER_TO_HARNESS_KEY mapped both to "opencode").
#
# - openrouter_free rows -> runner_key: "opencode",
#   config.opencode.model_policy = "free". tier_model_ids, provider_api_key,
#   flags, and weights are left untouched.
# - openrouter_pareto rows -> runner_key: "opencode",
#   config.opencode.model = "openrouter/pareto-code",
#   config.opencode.model_policy = "specific" (an ordinary catalog row —
#   RDR-065 D3).
#
# Runner row IDs (and therefore routing_key "runner:<id>") are preserved by
# updating in place rather than recreating rows, so runner:<id> identifiers,
# parked runs, quotas, and RunnerState survive.
#
# Free-model rotation state (per-model rate limits, preferred_tier_model_ids
# recovery snapshots) previously lived on a RunnerState row keyed by the
# bare legacy runner_key ("openrouter_free" / "openrouter_pareto") because
# openrouter_free was guaranteed single-instance. opencode is not
# single-instance, so that state is rekeyed onto the surviving runner's
# routing-key state ("runner:<id>") to avoid collisions across a user's
# other opencode runners; app/models/runner.rb and
# app/services/free_models/rotation.rb read/write free-policy RunnerState by
# that same routing key going forward.
#
# Idempotent and safe to run while the legacy keys still execute: a second
# run finds no rows with runner_key in the legacy set and is a no-op.
class MigrateOpenrouterFreeParetoRunnersToOpencode < ActiveRecord::Migration[8.1]
  class MigrationRunner < ActiveRecord::Base
    self.table_name = "runners"
  end

  class MigrationRunnerState < ActiveRecord::Base
    self.table_name = "runner_states"
  end

  LEGACY_FREE_KEY = "openrouter_free"
  LEGACY_PARETO_KEY = "openrouter_pareto"
  LEGACY_KEYS = [ LEGACY_FREE_KEY, LEGACY_PARETO_KEY ].freeze
  TARGET_KEY = "opencode"
  PARETO_MODEL_ID = "openrouter/pareto-code"

  def up
    migrated = migrate_runners!
    migrate_runner_states!(migrated)
  end

  def down
    # Intentionally no-op: the legacy openrouter_free/openrouter_pareto
    # runner keys and their dedicated code paths are removed in this same
    # PR, so reverting the data without reverting the code would leave
    # unroutable runner rows.
  end

  private

  def migrate_runners!
    migrated = []

    MigrationRunner.where(runner_key: LEGACY_KEYS).find_each do |runner|
      legacy_key = runner.runner_key
      migrate_runner!(runner, legacy_key)
      migrated << {
        user_id: runner.user_id,
        legacy_key: legacy_key,
        runner_id: runner.id,
        discarded: runner.discarded_at.present?
      }
    end

    migrated
  end

  def migrate_runner!(runner, legacy_key)
    config = runner.config.is_a?(Hash) ? runner.config.deep_dup : {}
    opencode_config = (config["opencode"].is_a?(Hash) ? config["opencode"] : {}).dup

    if legacy_key == LEGACY_FREE_KEY
      opencode_config["model_policy"] = "free"
    else
      opencode_config["model"] = PARETO_MODEL_ID
      opencode_config["model_policy"] = "specific"
    end

    config["opencode"] = opencode_config

    runner.update_columns(
      runner_key: TARGET_KEY,
      provider_key: TARGET_KEY,
      config: config,
      name: disambiguated_name(runner),
      updated_at: Time.current
    )
  end

  # Avoid violating idx_runners_unique_api_key (user_id, runner_key,
  # provider_api_key_id, name) if the user already holds (or is, in this
  # same migration run, gaining) another kept "opencode" api_key row with
  # the same provider_api_key_id and name. Renaming is scoped to exactly
  # this case; runners with no conflict keep their existing name unchanged.
  def disambiguated_name(runner)
    return runner.name unless runner.auth_type == "api_key" && runner.discarded_at.nil?
    return runner.name unless conflicting_opencode_row?(runner)

    "Migrated #{runner.name.presence || runner.runner_key} ##{runner.id}"
  end

  def conflicting_opencode_row?(runner)
    MigrationRunner.where(
      user_id: runner.user_id,
      runner_key: TARGET_KEY,
      auth_type: "api_key",
      provider_api_key_id: runner.provider_api_key_id,
      discarded_at: nil
    ).where(name: runner.name.to_s).where.not(id: runner.id).exists?
  end

  def migrate_runner_states!(migrated)
    survivor_runner_id_by_user_and_key(migrated).each do |(user_id, legacy_key), runner_id|
      state = MigrationRunnerState.find_by(user_id: user_id, runner_name: legacy_key)
      next unless state

      rekey_state!(state, target_name: "runner:#{runner_id}")
    end
  end

  # At most one RunnerState row exists per (user, legacy bare key) —
  # runner_states has a unique index on (user_id, runner_name) — even when a
  # user holds several runners under the same legacy key. Pick a
  # deterministic survivor (prefer a kept row, else the lowest id) to own
  # that state going forward.
  def survivor_runner_id_by_user_and_key(migrated)
    migrated.group_by { |row| [ row[:user_id], row[:legacy_key] ] }.transform_values do |rows|
      (rows.find { |row| !row[:discarded] } || rows.min_by { |row| row[:runner_id] })[:runner_id]
    end
  end

  def rekey_state!(legacy_state, target_name:)
    existing = MigrationRunnerState.find_by(user_id: legacy_state.user_id, runner_name: target_name)

    if existing
      merge_state_metadata!(existing, legacy_state)
    else
      legacy_state.update_columns(runner_name: target_name, updated_at: Time.current)
    end
  end

  # The routing-key row (if any) reflects live per-runner-id tracking
  # (health checks, quota snapshots) and takes precedence; only metadata
  # keys absent from it are backfilled from the legacy bare-key row before
  # the legacy row is discarded.
  def merge_state_metadata!(existing, legacy_state)
    merged_metadata = (legacy_state.metadata || {}).merge(existing.metadata || {})
    existing.update_columns(metadata: merged_metadata, updated_at: Time.current)
    legacy_state.destroy
  end
end
