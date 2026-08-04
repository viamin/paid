# frozen_string_literal: true

class CreateCoordinationPolicies < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      create_table :coordination_policies, comment: "Versioned coordination policy catalogs that drive decomposition, recovery, escalation, and lifecycle decisions." do |t|
        t.references :account, null: false, foreign_key: { on_delete: :cascade }, comment: "Tenant that owns this policy family."
        t.references :project, foreign_key: { on_delete: :cascade }, comment: "Optional project-specific override; nil means account-wide default."
        t.string :policy_type, limit: 50, null: false, comment: "Decision domain controlled by this policy: decomposition, recovery, escalation, or lifecycle_state."
        t.string :policy_key, limit: 100, null: false, comment: "Stable identifier used by runtime policy selection."
        t.string :name, null: false, comment: "Human-readable policy name shown in admin and experiment tooling."
        t.text :description, comment: "Long-form summary of what this policy is intended to optimize or protect."
        t.string :status, limit: 30, null: false, default: "draft", comment: "Catalog lifecycle state: draft, active, or archived."
        t.jsonb :context_selector, null: false, default: {}, comment: "Structured selector used to decide when this policy applies."
        t.jsonb :metadata, null: false, default: {}, comment: "Additional structured provenance, rollout, and audit details."

        t.timestamps
      end

      create_table :coordination_policy_versions, comment: "Immutable policy revisions that carry the executable rules and tunable parameters for a coordination policy." do |t|
        t.references :coordination_policy, null: false, foreign_key: { on_delete: :cascade }, comment: "Owning policy catalog entry."
        t.integer :version, null: false, comment: "Monotonic version number within the owning coordination policy."
        t.string :status, limit: 30, null: false, default: "draft", comment: "Revision lifecycle state: draft, active, superseded, or retired."
        t.jsonb :rules, null: false, default: {}, comment: "Structured decision rules executed by coordination services."
        t.jsonb :parameters, null: false, default: {}, comment: "Thresholds, weights, and other tunable policy parameters."
        t.text :llm_prompt, comment: "Optional prompt template used when the policy delegates part of the decision to an LLM."
        t.text :reasoning, comment: "Why this policy version exists and what changed from the prior version."
        t.jsonb :metadata, null: false, default: {}, comment: "Structured provenance such as generator metadata, rollout notes, and approval state."
        t.datetime :activated_at, comment: "When this version became the policy's active revision."
        t.datetime :retired_at, comment: "When this version stopped being eligible for runtime selection."

        t.timestamps
      end

      add_reference :coordination_policies,
        :current_version,
        foreign_key: { to_table: :coordination_policy_versions, on_delete: :nullify },
        index: true

      add_index :coordination_policies, [ :account_id, :policy_type, :status ],
        name: "idx_coordination_policies_account_type_status"
      add_index :coordination_policies, [ :project_id, :policy_type, :status ],
        name: "idx_coordination_policies_project_type_status"
      add_index :coordination_policies, [ :account_id, :policy_type, :policy_key ],
        unique: true,
        where: "project_id IS NULL",
        name: "idx_coordination_policies_account_scope_key"
      add_index :coordination_policies, [ :account_id, :project_id, :policy_type, :policy_key ],
        unique: true,
        where: "project_id IS NOT NULL",
        name: "idx_coordination_policies_project_scope_key"

      add_index :coordination_policy_versions, [ :coordination_policy_id, :version ],
        unique: true,
        name: "idx_coordination_policy_versions_unique_version"
      add_index :coordination_policy_versions, :coordination_policy_id,
        unique: true,
        where: "status = 'active'",
        name: "idx_coordination_policy_versions_one_active"
      add_index :coordination_policy_versions, [ :coordination_policy_id, :status, :created_at ],
        name: "idx_coordination_policy_versions_policy_status_created"

      enable_row_level_security
    end
  end

  def down
    safety_assured do
      %w[coordination_policy_versions coordination_policies].each do |table|
        qualified_table = current_schema_table_name(table)
        next unless table_exists?(qualified_table)

        execute "DROP POLICY IF EXISTS tenant_isolation ON #{qualified_table}"
        execute "ALTER TABLE #{qualified_table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{qualified_table} DISABLE ROW LEVEL SECURITY"
      end

      execute "ALTER TABLE #{current_schema_table_name("coordination_policies")} DROP CONSTRAINT IF EXISTS fk_rails_e1e816c81c"
      execute "ALTER TABLE #{current_schema_table_name("coordination_policies")} DROP COLUMN IF EXISTS current_version_id"
      execute "DROP TABLE IF EXISTS #{current_schema_table_name("coordination_policy_versions")} CASCADE"
      execute "DROP TABLE IF EXISTS #{current_schema_table_name("coordination_policies")} CASCADE"
    end
  end

  private

  def current_schema_table_name(table_name)
    %(#{connection.quote_table_name(current_schema_name)}.#{connection.quote_table_name(table_name)})
  end

  def current_schema_name
    @current_schema_name ||= connection.select_value("SELECT current_schema()")
  end

  def enable_row_level_security
    execute <<~SQL
      ALTER TABLE coordination_policies ENABLE ROW LEVEL SECURITY;
      ALTER TABLE coordination_policies FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON coordination_policies
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR (#{coordination_policy_tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{coordination_policy_tenant_condition}));
    SQL

    execute <<~SQL
      ALTER TABLE coordination_policy_versions ENABLE ROW LEVEL SECURITY;
      ALTER TABLE coordination_policy_versions FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON coordination_policy_versions
        AS PERMISSIVE FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM coordination_policies
            WHERE coordination_policies.id = coordination_policy_versions.coordination_policy_id
              AND coordination_policies.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM coordination_policies
            WHERE coordination_policies.id = coordination_policy_versions.coordination_policy_id
              AND coordination_policies.account_id = paid_current_account_id()
          )
        );
    SQL
  end

  def coordination_policy_tenant_condition
    <<~SQL.squish
      coordination_policies.account_id = paid_current_account_id()
      AND (
        coordination_policies.project_id IS NULL
        OR EXISTS (
          SELECT 1 FROM projects
          WHERE projects.id = coordination_policies.project_id
            AND projects.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
