# frozen_string_literal: true

class CreateProjectConventionOverrides < ActiveRecord::Migration[8.1]
  def change
    create_table :project_convention_overrides,
      comment: "Explicit per-project overrides for detected repository conventions." do |t|
      t.references :project, null: false, foreign_key: true, comment: "Project receiving the explicit convention override."
      t.string :key, null: false, comment: "Convention key being overridden, such as commit_messages."
      t.jsonb :value, null: false, default: {}, comment: "Explicit project-scoped convention override payload."
      t.text :rationale, comment: "User-entered reason for overriding the detected convention."
      t.boolean :enabled, null: false, default: true, comment: "Disabled overrides act as tombstones against detected defaults."

      t.timestamps
    end

    add_index :project_convention_overrides, [ :project_id, :key ], unique: true
  end
end
