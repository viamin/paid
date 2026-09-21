# frozen_string_literal: true

class CreateModelAvailabilityChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :model_availability_checks, comment: "Per (model, runner, auth, account) availability evidence from " \
      "reconciliation, kept distinct from the global LlmModel catalog so a scheduled sync cannot silently " \
      "undo a validated availability change or a structured runtime rejection." do |t|
      t.references :llm_model, null: false, foreign_key: true
      t.string :runner_key, null: false
      t.string :auth_type, null: false
      t.references :account, null: true, foreign_key: true, comment: "Null means an account-agnostic (global) reconciliation context."
      t.string :status, null: false, comment: "available or unavailable, as of checked_at."
      t.string :source, null: false, comment: "What produced this evidence, e.g. agent_harness_compat or runtime_rejection."
      t.text :reason
      t.string :incompatibility_type
      t.string :replacement_model_id, comment: "Policy-eligible candidate suggested at the time of a rejection, never a hardcoded universal fallback."
      t.string :attempted_model_id, comment: "The model id actually attempted, which may differ from llm_model_id's model_id."
      t.integer :retry_count, null: false, default: 0
      t.datetime :checked_at, null: false
      t.datetime :expires_at, comment: "Bounds how long this evidence is trusted before reconciliation must refresh it."

      t.timestamps
    end

    add_index :model_availability_checks, [ :llm_model_id, :runner_key, :auth_type, :account_id ],
      unique: true, where: "account_id IS NOT NULL", name: "idx_availability_checks_unique_scoped"
    add_index :model_availability_checks, [ :llm_model_id, :runner_key, :auth_type ],
      unique: true, where: "account_id IS NULL", name: "idx_availability_checks_unique_global"
    add_index :model_availability_checks, :status
  end
end
