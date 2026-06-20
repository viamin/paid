# frozen_string_literal: true

class AddPausedToIssues < ActiveRecord::Migration[8.1]
  def change
    # The canonical local mirror of the `paid-paused` GitHub label.
    # `paused_at` doubles as the sync epoch: it records when the pause
    # state last transitioned (from either the UI or GitHub) so the
    # bidirectional sync can reject stale/out-of-order events.
    add_column :issues, :paused, :boolean, default: false, null: false
    add_column :issues, :paused_at, :datetime, comment: "Sync epoch: records when the pause state last transitioned (from UI or GitHub) to resolve bidirectional sync ordering."
  end
end
