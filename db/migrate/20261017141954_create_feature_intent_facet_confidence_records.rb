# frozen_string_literal: true

# @spec FACET-CONFIDENCE-001 @spec FACET-CONFIDENCE-002 @spec FACET-CONFIDENCE-008
class CreateFeatureIntentFacetConfidenceRecords < ActiveRecord::Migration[8.1]
  TABLES = %i[feature_intent_facets feature_intent_facet_directions feature_intent_facet_evidence feature_intent_facet_assessments feature_intent_issue_prerequisite_mappings feature_intent_issue_prerequisites].freeze

  def up
    create_facets
    create_directions
    create_evidence
    create_assessments
    create_issue_mappings
    create_prerequisites
    TABLES.each { |table| apply_rls(table) }
  end

  def down
    TABLES.reverse_each { |table| remove_rls(table) }
    TABLES.reverse_each { |table| drop_table table }
  end

  private

  def create_facets
    create_table :feature_intent_facets, comment: "Named tenant-owned feature or issue aspects assessed independently." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent, null: false, foreign_key: { on_delete: :cascade }
      t.references :issue, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_decision, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.text :design_claim, null: false
      t.integer :evidence_revision, null: false, default: 0
      t.jsonb :log_data
      t.timestamps
    end
    add_index :feature_intent_facets, %i[feature_intent_id issue_id]
    add_index :feature_intent_facets, %i[account_id feature_intent_id]
  end

  def create_directions
    create_table :feature_intent_facet_directions, comment: "Candidate directions for a facet; scores belong to a direction." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_facet, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description, null: false
      t.string :status, null: false, default: "active"
      t.jsonb :log_data
      t.timestamps
    end
    add_index :feature_intent_facet_directions, %i[feature_intent_facet_id name], unique: true
    add_check_constraint :feature_intent_facet_directions, "status IN ('active', 'superseded')", name: "facet_direction_status"
  end

  def create_evidence
    create_table :feature_intent_facet_evidence, comment: "Attributable evidence retained independently of temporary visual artifacts." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_facet, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_facet_direction, foreign_key: { on_delete: :nullify }
      t.references :feature_intent_decision, foreign_key: { on_delete: :nullify }
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :superseded_by, foreign_key: { to_table: :feature_intent_facet_evidence, on_delete: :nullify }
      t.string :source_type, null: false
      t.string :source_reference, null: false
      t.string :idempotency_key, null: false
      t.text :statement, null: false
      t.text :textual_context
      t.datetime :occurred_at, null: false
      t.integer :evidence_revision, null: false
      t.timestamps
    end
    add_index :feature_intent_facet_evidence, %i[account_id idempotency_key], unique: true, name: "index_facet_evidence_idempotency"
    add_index :feature_intent_facet_evidence, %i[feature_intent_facet_id evidence_revision]
  end

  def create_assessments
    create_table :feature_intent_facet_assessments, comment: "Versioned agent assessments of candidate directions against facet evidence." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_facet_direction, null: false, foreign_key: { on_delete: :cascade }
      t.integer :evidence_revision, null: false
      t.string :status, null: false, default: "unknown"
      t.integer :intent_score
      t.integer :technical_score
      t.text :explanation, null: false, default: ""
      t.string :rubric_version, null: false
      t.string :model_version, null: false
      t.jsonb :evidence_references, null: false, default: []
      t.datetime :assessed_at
      t.timestamps
    end
    add_index :feature_intent_facet_assessments, %i[feature_intent_facet_direction_id evidence_revision], name: "index_facet_assessments_direction_revision"
    add_check_constraint :feature_intent_facet_assessments, "intent_score BETWEEN 0 AND 100 OR intent_score IS NULL", name: "facet_assessments_intent_bounds"
    add_check_constraint :feature_intent_facet_assessments, "technical_score BETWEEN 0 AND 100 OR technical_score IS NULL", name: "facet_assessments_technical_bounds"
    add_check_constraint :feature_intent_facet_assessments, "status IN ('unknown', 'pending', 'completed', 'failed', 'superseded')", name: "facet_assessment_status"
  end

  def create_issue_mappings
    create_table :feature_intent_issue_prerequisite_mappings, comment: "Audited coverage and design baseline for one linked issue's prerequisites." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_issue, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :coverage_assessment, null: false, default: "unknown"
      t.text :coverage_rationale, null: false, default: ""
      t.string :scope_revision
      t.jsonb :relevant_design_documents, null: false, default: []
      t.jsonb :log_data
      t.timestamps
    end
    add_check_constraint :feature_intent_issue_prerequisite_mappings, "coverage_assessment IN ('unknown', 'incomplete', 'complete')", name: "issue_prerequisite_mapping_coverage"
  end

  def create_prerequisites
    create_table :feature_intent_issue_prerequisites, comment: "Material facet directions required before a linked issue can become ready." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_issue_prerequisite_mapping, null: false, foreign_key: { on_delete: :cascade }
      t.references :feature_intent_facet, null: false, foreign_key: { on_delete: :restrict }
      t.references :feature_intent_facet_direction, foreign_key: { on_delete: :restrict }
      t.text :materiality_rationale, null: false
      t.jsonb :log_data
      t.timestamps
    end
    add_index :feature_intent_issue_prerequisites, %i[feature_intent_issue_prerequisite_mapping_id feature_intent_facet_id feature_intent_facet_direction_id], unique: true, name: "index_issue_prerequisites_unique_mapping"
  end

  def apply_rls(table)
    safety_assured do
      execute <<~SQL
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON #{table} AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (#{table}.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (#{table}.account_id = paid_current_account_id()));
      SQL
    end
  end

  def remove_rls(table)
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end
end
