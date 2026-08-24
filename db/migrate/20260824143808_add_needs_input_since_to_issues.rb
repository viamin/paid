# frozen_string_literal: true

class AddNeedsInputSinceToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    return if column_exists?(:issues, :needs_input_since)

    add_column :issues, :needs_input_since, :datetime,
      comment: "When this issue entered paid_state \"needs_input\". Cleared when it leaves. " \
               "Used by Inbox::Queue to order oldest-waiting-first and to render \"waiting Xh\" labels."

    # Backfill existing rows: for issues already in needs_input, the safest
    # local fallback is updated_at (the latest GitHub refresh that observed
    # the needs_input state). Per-issue GitHub comment timestamps are not
    # stored locally, so a comment-aware backfill would require API calls
    # that are infeasible at migration time. The UPDATE is wrapped in
    # safety_assured because strong_migrations cannot inspect raw SQL; the
    # statement is safe (a column-default backfill on an existing nullable
    # column, scoped to rows already in the matching paid_state).
    safety_assured do
      execute <<~SQL.squish
        UPDATE issues
           SET needs_input_since = updated_at
         WHERE paid_state = 'needs_input'
           AND needs_input_since IS NULL
      SQL
    end

    # Partial index scoped to the active needs_input rows so the inbox queue
    # can do an index-only scan of "open oldest-first" without touching the
    # full issues table. Concurrent build avoids blocking writes on the
    # issues table during deploy (strong_migrations requirement).
    unless index_exists?(:issues, :needs_input_since, where: "paid_state = 'needs_input'")
      safety_assured do
        execute <<~SQL.squish
          CREATE INDEX CONCURRENTLY index_issues_needs_input_since_active
            ON issues (needs_input_since ASC)
            WHERE paid_state = 'needs_input'
        SQL
      end
    end
  end

  def down
    if index_exists?(:issues, :needs_input_since, name: "index_issues_needs_input_since_active")
      remove_index :issues, name: "index_issues_needs_input_since_active", algorithm: :concurrently
    end

    if column_exists?(:issues, :needs_input_since)
      remove_column :issues, :needs_input_since
    end
  end
end
