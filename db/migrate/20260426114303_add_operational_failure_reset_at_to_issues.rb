# frozen_string_literal: true

class AddOperationalFailureResetAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :operational_failure_reset_at, :datetime
  end
end
