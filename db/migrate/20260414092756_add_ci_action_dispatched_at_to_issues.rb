# frozen_string_literal: true

class AddCiActionDispatchedAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :ci_action_dispatched_at, :datetime
  end
end
