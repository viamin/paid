# frozen_string_literal: true

class AddCiRetryRequestedAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :ci_retry_requested_at, :datetime
  end
end
