# frozen_string_literal: true

class ValidateCascadeLayeredVerificationFindingOwners < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :layered_verification_findings, :layered_verification_obligations
    validate_foreign_key :layered_verification_findings, :agent_runs
  end
end
