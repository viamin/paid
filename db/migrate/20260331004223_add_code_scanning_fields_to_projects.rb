# frozen_string_literal: true

class AddCodeScanningFieldsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_code_scanning_scan_at, :datetime
    add_column :projects, :code_scanning_interval_hours, :integer, default: 72, null: false
  end
end
