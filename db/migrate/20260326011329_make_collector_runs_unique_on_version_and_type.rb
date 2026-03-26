# frozen_string_literal: true

class MakeCollectorRunsUniqueOnVersionAndType < ActiveRecord::Migration[8.1]
  def change
    remove_index :collector_runs, [ :project_version_id, :collector_type ]
    add_index :collector_runs, [ :project_version_id, :collector_type ], unique: true
  end
end
