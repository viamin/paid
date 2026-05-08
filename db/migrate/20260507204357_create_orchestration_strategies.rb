# frozen_string_literal: true

class CreateOrchestrationStrategies < ActiveRecord::Migration[8.1]
  def change
    create_table :orchestration_strategies, comment: "Persisted orchestration workflow configurations extracted from hardcoded defaults" do |t|
      t.references :account, null: true, foreign_key: true, comment: "NULL = system-wide default; set = account-level override"
      t.string :strategy_type, null: false, comment: "Category: review_settings, quality_gate, execution_timeouts, retry_policies, agent_settings, feature_orchestration, provider_resolution"
      t.string :name, null: false, comment: "Human-readable name for this strategy"
      t.integer :version, null: false, default: 1, comment: "Monotonically increasing version for audit trail"
      t.jsonb :configuration, null: false, default: {}, comment: "Strategy-specific configuration data"
      t.boolean :active, null: false, default: true, comment: "Whether this strategy is currently in effect"
      t.timestamps
    end

    add_index :orchestration_strategies, [ :strategy_type, :account_id ],
      unique: true,
      where: "active = true",
      name: "idx_orchestration_strategies_active_type_account"
    add_index :orchestration_strategies, :strategy_type
    add_index :orchestration_strategies, :active
  end
end
