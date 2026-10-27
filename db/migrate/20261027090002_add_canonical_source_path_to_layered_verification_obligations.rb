# frozen_string_literal: true

class AddCanonicalSourcePathToLayeredVerificationObligations < ActiveRecord::Migration[8.1]
  def change
    add_column :layered_verification_obligations, :canonical_source_path, :string
  end
end
