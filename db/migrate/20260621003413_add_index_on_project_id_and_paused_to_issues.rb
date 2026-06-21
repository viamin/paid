# frozen_string_literal: true

class AddIndexOnProjectIdAndPausedToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :issues, [ :project_id, :paused ],
      name: "index_issues_on_project_id_and_paused",
      algorithm: :concurrently
  end
end
