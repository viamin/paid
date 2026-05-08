# frozen_string_literal: true

class CreateConfigurationBundles < ActiveRecord::Migration[8.1]
  def change
    create_table :configuration_bundles, comment: "Versioned snapshots of configuration components used for agent runs" do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, foreign_key: { on_delete: :cascade },
        comment: "Optional project scope; NULL means account-wide bundle"
      t.references :prompt_version, foreign_key: { on_delete: :nullify },
        comment: "The prompt template version included in this bundle"
      t.references :llm_model, foreign_key: { on_delete: :nullify },
        comment: "The LLM model included in this bundle"
      t.integer :version, null: false, default: 1,
        comment: "Monotonic version number within the account/project scope"
      t.string :name, null: false, limit: 255
      t.text :description
      t.string :status, null: false, default: "draft", limit: 50,
        comment: "Lifecycle state: draft, active, retired"
      t.string :strategy, limit: 100,
        comment: "Orchestration strategy identifier (e.g. single_agent, multi_agent)"
      t.jsonb :strategy_params, null: false, default: {},
        comment: "Strategy-specific parameters (concurrency, escalation thresholds, etc.)"
      t.jsonb :context, null: false, default: {},
        comment: "Additional context such as guardrails, token budgets, or feature flags"
      t.string :fingerprint, limit: 64,
        comment: "Content-addressable hash for deduplication"
      t.datetime :activated_at, comment: "When the bundle was promoted to active"
      t.datetime :retired_at, comment: "When the bundle was retired"

      t.timestamps
    end

    create_table :bundle_outcomes, comment: "Measured results from using a configuration bundle on an agent run" do |t|
      t.references :configuration_bundle, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.decimal :quality_score, precision: 5, scale: 4,
        comment: "Overall quality score (0.0-1.0)"
      t.integer :duration_seconds,
        comment: "Wall-clock time for the agent run"
      t.integer :cost_cents,
        comment: "Total cost of the agent run in cents"
      t.integer :tokens_used,
        comment: "Total tokens (input + output) consumed"
      t.boolean :success, null: false, default: false,
        comment: "Whether the agent run completed successfully"
      t.jsonb :metrics, null: false, default: {},
        comment: "Additional outcome metrics (lines changed, test pass rate, etc.)"

      t.timestamps
    end

    add_index :configuration_bundles, [ :account_id, :project_id, :version ],
      unique: true,
      name: "index_config_bundles_unique_version"
    add_index :configuration_bundles, [ :account_id, :status ],
      name: "index_config_bundles_on_account_status"
    add_index :configuration_bundles, [ :project_id, :status ],
      name: "index_config_bundles_on_project_status"
    add_index :configuration_bundles, :fingerprint,
      unique: true,
      where: "fingerprint IS NOT NULL",
      name: "index_config_bundles_unique_fingerprint"
    add_index :configuration_bundles, :status

    add_index :bundle_outcomes, [ :configuration_bundle_id, :agent_run_id ],
      unique: true,
      name: "index_bundle_outcomes_unique_run"
    add_index :bundle_outcomes, :quality_score
    add_index :bundle_outcomes, :success
  end
end
