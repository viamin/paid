# frozen_string_literal: true

class AddLastIssueSyncAtToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_issue_sync_at, :datetime
  end
end
