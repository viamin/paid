# frozen_string_literal: true

class AddLastCommentSyncAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :last_comment_sync_at, :datetime
  end
end
