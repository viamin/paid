# frozen_string_literal: true

class CascadeLayeredVerificationFindingOwners < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :layered_verification_findings, :layered_verification_obligations
    add_foreign_key :layered_verification_findings, :layered_verification_obligations,
      column: :obligation_id, on_delete: :cascade, validate: false

    remove_foreign_key :layered_verification_findings, :agent_runs
    add_foreign_key :layered_verification_findings, :agent_runs, on_delete: :cascade, validate: false
  end
end
