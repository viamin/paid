# frozen_string_literal: true

class ValidateForeignKeysOnStalledCloseoutProjection < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      validate_foreign_key :stalled_closeout_projection_checks, :projects
      validate_foreign_key :stalled_closeout_projection_rows, :projects
      validate_foreign_key :stalled_closeout_projection_rows, :issues
    end
  end

  def down
    # Validation is one-way: the FKs stay valid once proven.
  end
end
