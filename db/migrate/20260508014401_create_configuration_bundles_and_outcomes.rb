# frozen_string_literal: true

class CreateConfigurationBundlesAndOutcomes < ActiveRecord::Migration[8.1]
  def change
    create_table :configuration_bundles, comment: "Versioned runtime configuration snapshots assigned to agent runs for optimization analysis." do |t|
      t.string :fingerprint, null: false, comment: "Deterministic SHA-256 digest of the canonical bundle definition."
      t.jsonb :definition, null: false, default: {}, comment: "Canonical configuration snapshot used by the assigned agent runs."

      t.timestamps
    end

    create_table :configuration_bundle_outcomes, comment: "Optimization-facing outcome metrics observed for a specific agent run and bundle pairing." do |t|
      t.references :configuration_bundle, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :status, null: false, comment: "Terminal agent run status captured for optimization analysis."
      t.decimal :quality_score, precision: 5, scale: 4, comment: "Composite quality score attributed to the completed agent run."
      t.integer :cost_cents, null: false, default: 0, comment: "Final agent run cost in cents."
      t.integer :duration_seconds, comment: "Final wall-clock duration recorded for the agent run."
      t.datetime :completed_at, comment: "When the agent run reached its terminal state."
      t.jsonb :component_scores, null: false, default: {}, comment: "Detailed quality component scores that contributed to the final quality score."

      t.timestamps
    end

    add_reference :agent_runs,
      :configuration_bundle,
      foreign_key: { on_delete: :nullify },
      index: true,
      comment: "Configuration bundle assigned to the run before execution."

    add_index :configuration_bundles, :fingerprint, unique: true
    add_index :configuration_bundle_outcomes, [ :configuration_bundle_id, :completed_at ]
  end
end
