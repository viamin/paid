# frozen_string_literal: true

class ChangeDefaultCodeScanningIntervalHoursTo24 < ActiveRecord::Migration[8.1]
  def change
    change_column_default :projects, :code_scanning_interval_hours, from: 72, to: 24

    reversible do |dir|
      dir.up { Project.where(code_scanning_interval_hours: 72).update_all(code_scanning_interval_hours: 24) }
    end
  end
end
