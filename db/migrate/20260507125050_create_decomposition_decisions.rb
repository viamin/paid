# frozen_string_literal: true

class CreateDecompositionDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :decomposition_decisions do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, comment: "Project whose issue decomposition flow produced this decision."
      t.references :issue, null: false, foreign_key: { on_delete: :cascade }, comment: "Parent issue being decomposed or parallelized."
      t.string :decision_key, null: false, comment: "Idempotency key for this workflow decision boundary."
      t.string :workflow_name, null: false, comment: "Temporal workflow class that emitted the decision."
      t.string :workflow_id, null: false, comment: "Temporal workflow identifier for correlation across activities."
      t.string :decision_type, null: false, comment: "Decision boundary being recorded, such as planning_outcome or parallelization_outcome."
      t.string :outcome, null: false, comment: "Observed outcome at the decision boundary."
      t.jsonb :input_context, null: false, default: {}, comment: "Issue and planning inputs available when the decision was made."
      t.jsonb :plan_data, null: false, default: {}, comment: "Generated tasks, created issues, and related plan artifacts."
      t.jsonb :hints, null: false, default: {}, comment: "Derived dependency and parallelism hints for later analysis."
      t.jsonb :error_details, null: false, default: {}, comment: "Failure details when the decision path ended exceptionally."
      t.jsonb :metadata, null: false, default: {}, comment: "Additional workflow metadata such as prompt source and activity boundaries."

      t.timestamps
    end

    add_index :decomposition_decisions, :decision_key, unique: true
    add_index :decomposition_decisions, [ :project_id, :created_at ]
    add_index :decomposition_decisions, [ :issue_id, :created_at ]
    add_index :decomposition_decisions, [ :workflow_id, :decision_type ]

    execute <<~SQL
      ALTER TABLE decomposition_decisions ENABLE ROW LEVEL SECURITY;
      ALTER TABLE decomposition_decisions FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON decomposition_decisions
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = decomposition_decisions.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = decomposition_decisions.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
    SQL
  end
end
