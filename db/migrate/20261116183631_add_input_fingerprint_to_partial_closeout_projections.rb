# frozen_string_literal: true

class AddInputFingerprintToPartialCloseoutProjections < ActiveRecord::Migration[8.1]
  def change
    add_column :partial_closeout_projections, :input_fingerprint, :string, limit: 64,
      comment: "Fingerprint of admission-input counts and latest updates."
  end
end
