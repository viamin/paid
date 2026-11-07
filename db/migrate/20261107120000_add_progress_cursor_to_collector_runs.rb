# frozen_string_literal: true

class AddProgressCursorToCollectorRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :collector_runs, :progress_cursor, :string
  end
end
