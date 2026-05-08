# frozen_string_literal: true

class CreateConfigurationBundlesAndBundleOutcomes < ActiveRecord::Migration[8.1]
  def up
    create_table :configuration_bundles,
      comment: "Versioned configuration bundles used by the outcome optimizer to select prompts, models, and orchestration settings." do |t|
      t.references :account,
        null: true,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Owning account. Null means the bundle is globally visible across accounts."
      t.string :name,
        null: false,
        limit: 255,
        comment: "Human-readable label for the bundle."
      t.text :description,
        comment: "Optional explanation of what the bundle is intended to optimize."
      t.jsonb :prompt_versions,
        null: false,
        default: {},
        comment: "Prompt version selections keyed by workflow role, such as planning, coding, or review."
      t.jsonb :model_preferences,
        null: false,
        default: {},
        comment: "Model or provider preferences keyed by workflow role."
      t.jsonb :orchestration_config,
        null: false,
        default: {},
        comment: "Orchestration settings such as retries, parallelism, or iteration limits."
      t.jsonb :thresholds,
        null: false,
        default: {},
        comment: "Quality, cost, or latency thresholds enforced for the bundle."
      t.jsonb :context_selector,
        null: false,
        default: {},
        comment: "Optional matcher metadata describing where this bundle should be considered."
      t.boolean :is_baseline,
        null: false,
        default: false,
        comment: "Marks the baseline configuration used before the optimizer has enough evidence."
      t.boolean :is_active,
        null: false,
        default: true,
        comment: "Controls whether the optimizer may consider this bundle for selection."
      t.timestamps
    end

    create_table :bundle_outcomes,
      comment: "Observed execution outcomes attributed to a specific configuration bundle and agent run." do |t|
      t.references :configuration_bundle,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Bundle whose execution produced this outcome."
      t.references :agent_run,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Agent run that executed the bundle."
      t.references :project,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Owning project used for tenant isolation and project-specific analysis."
      t.jsonb :context_features,
        null: false,
        default: {},
        comment: "Structured context captured at execution time for surrogate-model training."
      t.decimal :outcome_score,
        null: false,
        precision: 5,
        scale: 4,
        comment: "Normalized objective value for the run, expected on the 0.0 to 1.0 scale."
      t.jsonb :component_scores,
        null: false,
        default: {},
        comment: "Supporting metrics that explain how the final outcome score was composed."
      t.timestamps
    end

    add_index :configuration_bundles, [ :account_id, :is_active, :id ], name: "idx_configuration_bundles_account_active"
    add_index :configuration_bundles,
      :account_id,
      unique: true,
      where: "is_baseline = true",
      name: "idx_configuration_bundles_one_baseline_per_account"
    add_index :configuration_bundles,
      :is_baseline,
      unique: true,
      where: "is_baseline = true AND account_id IS NULL",
      name: "idx_configuration_bundles_one_global_baseline"
    add_index :bundle_outcomes, [ :configuration_bundle_id, :created_at, :id ], name: "idx_bundle_outcomes_bundle_recent"
    add_index :bundle_outcomes, [ :project_id, :created_at, :id ], name: "idx_bundle_outcomes_project_recent"
    add_index :bundle_outcomes, :agent_run_id, unique: true, name: "idx_bundle_outcomes_agent_run_unique"

    execute <<~SQL
      ALTER TABLE configuration_bundles ENABLE ROW LEVEL SECURITY;
      ALTER TABLE configuration_bundles FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON configuration_bundles
        USING (
          paid_tenant_bypass() OR account_id IS NULL OR account_id = paid_current_account_id()
        )
        WITH CHECK (
          paid_tenant_bypass() OR account_id IS NULL OR account_id = paid_current_account_id()
        );

      ALTER TABLE bundle_outcomes ENABLE ROW LEVEL SECURITY;
      ALTER TABLE bundle_outcomes FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON bundle_outcomes
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = bundle_outcomes.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = bundle_outcomes.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS tenant_isolation ON bundle_outcomes"
    execute "ALTER TABLE bundle_outcomes NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE bundle_outcomes DISABLE ROW LEVEL SECURITY"

    execute "DROP POLICY IF EXISTS tenant_isolation ON configuration_bundles"
    execute "ALTER TABLE configuration_bundles NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE configuration_bundles DISABLE ROW LEVEL SECURITY"

    drop_table :bundle_outcomes
    drop_table :configuration_bundles
  end
end
