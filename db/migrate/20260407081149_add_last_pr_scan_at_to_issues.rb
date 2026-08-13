# frozen_string_literal: true

class AddLastPrScanAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :last_pr_scan_at, :datetime
  end
end
