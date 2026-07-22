# frozen_string_literal: true

class CreatePreviewProvisionStates < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_provision_states,
      comment: "Shared baseline snapshots for overlapping preview/screenshot provisioning on the same agent run." do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.integer :active_count, null: false, default: 0,
        comment: "Number of in-flight preview provisions currently sharing this baseline snapshot."
      t.jsonb :baseline_service_container_ids, null: false, default: [],
        comment: "Agent run service container ids before the first overlapping preview mutated the run state."
      t.jsonb :baseline_service_environment, null: false, default: {},
        comment: "Agent run service environment before the first overlapping preview mutated the run state."
      t.timestamps
    end
  end
end
