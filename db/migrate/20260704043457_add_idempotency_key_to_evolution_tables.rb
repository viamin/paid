# frozen_string_literal: true

class AddIdempotencyKeyToEvolutionTables < ActiveRecord::Migration[8.1]
  # Adds an `idempotency_key` column to the side-effecting evolution tables so
  # that Temporal activity retries (worker crash after write, before Temporal
  # records completion) can detect and reuse the rows a previous attempt
  # already created instead of duplicating them. See #2770.
  disable_ddl_transaction!

  def up
    add_column :prompt_versions, :idempotency_key, :string unless column_exists?(:prompt_versions, :idempotency_key)
    add_concurrent_unique_index(:prompt_versions, [ :prompt_id, :idempotency_key ],
      "index_prompt_versions_on_prompt_and_idempotency_key")

    add_column :ab_tests, :idempotency_key, :string unless column_exists?(:ab_tests, :idempotency_key)
    add_concurrent_unique_index(:ab_tests, [ :prompt_id, :idempotency_key ],
      "index_ab_tests_on_prompt_and_idempotency_key")

    add_column :orchestration_strategies, :idempotency_key, :string unless column_exists?(:orchestration_strategies, :idempotency_key)
    add_concurrent_unique_index(:orchestration_strategies, [ :account_id, :strategy_type, :idempotency_key ],
      "index_orchestration_strategies_on_idempotency_key")

    add_column :strategy_experiments, :idempotency_key, :string unless column_exists?(:strategy_experiments, :idempotency_key)
    add_concurrent_unique_index(:strategy_experiments, [ :account_id, :strategy_name, :idempotency_key ],
      "index_strategy_experiments_on_idempotency_key")

    add_column :coordination_policy_versions, :idempotency_key, :string unless column_exists?(:coordination_policy_versions, :idempotency_key)
    add_concurrent_unique_index(:coordination_policy_versions, [ :coordination_policy_id, :idempotency_key ],
      "index_coordination_policy_versions_on_idempotency_key")
  end

  def down
    remove_concurrent_unique_index(:prompt_versions, "index_prompt_versions_on_prompt_and_idempotency_key")
    remove_column :prompt_versions, :idempotency_key if column_exists?(:prompt_versions, :idempotency_key)

    remove_concurrent_unique_index(:ab_tests, "index_ab_tests_on_prompt_and_idempotency_key")
    remove_column :ab_tests, :idempotency_key if column_exists?(:ab_tests, :idempotency_key)

    remove_concurrent_unique_index(:orchestration_strategies, "index_orchestration_strategies_on_idempotency_key")
    remove_column :orchestration_strategies, :idempotency_key if column_exists?(:orchestration_strategies, :idempotency_key)

    remove_concurrent_unique_index(:strategy_experiments, "index_strategy_experiments_on_idempotency_key")
    remove_column :strategy_experiments, :idempotency_key if column_exists?(:strategy_experiments, :idempotency_key)

    remove_concurrent_unique_index(:coordination_policy_versions, "index_coordination_policy_versions_on_idempotency_key")
    remove_column :coordination_policy_versions, :idempotency_key if column_exists?(:coordination_policy_versions, :idempotency_key)
  end

  private

  def add_concurrent_unique_index(table, columns, name)
    return if index_exists?(table, columns, name: name)

    add_index table, columns, name: name, unique: true,
      where: "idempotency_key IS NOT NULL", algorithm: :concurrently
  end

  def remove_concurrent_unique_index(table, name)
    return unless index_exists?(table, nil, name: name)

    remove_index table, name: name, algorithm: :concurrently
  end
end
