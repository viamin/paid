# frozen_string_literal: true

class AddCauseSignatureToLayeredVerificationCheckResults < ActiveRecord::Migration[8.1]
  def change
    add_column :layered_verification_check_results, :cause_signature, :string,
      comment: "Stable detector-provided identity for the underlying discrepancy; evidence locations are observation-specific."
  end
end
