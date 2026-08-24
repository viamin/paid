# frozen_string_literal: true

class AddNeedsInputSinceToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!
  INDEX_NAME = "index_issues_needs_input_since_active"

  def up
    # Each step is guarded independently rather than short-circuiting at the
    # top of #up. The CONCURRENTLY index build can fail mid-deploy after
    # `add_column` has already committed; an early `return` would then skip
    # the backfill and the index creation on every subsequent rerun, leaving
    # `needs_input_since` unindexed and NULL for legacy `needs_input` rows.
    # Per-step guards make every statement a no-op on rerun and let a partial
    # failure be resumed cleanly from the first incomplete step.
    unless column_exists?(:issues, :needs_input_since)
      add_column :issues, :needs_input_since, :datetime,
        comment: "When this issue entered paid_state \"needs_input\". Cleared when it leaves. " \
                 "Used by Inbox::Queue to order oldest-waiting-first and to render \"waiting Xh\" labels."
    end

    # Backfill existing rows: for issues already in needs_input, the safest
    # local fallback is updated_at (the latest GitHub refresh that observed
    # the needs_input state). Per-issue GitHub comment timestamps are not
    # stored locally, so a comment-aware backfill would require API calls
    # that are infeasible at migration time. The UPDATE is wrapped in
    # safety_assured because strong_migrations cannot inspect raw SQL; the
    # statement is safe (a column-default backfill on an existing nullable
    # column, scoped to rows already in the matching paid_state). The IS
    # NULL predicate makes this idempotent so a rerun picks up any rows
    # the column was added for but the backfill had not yet reached.
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
    ensure_needs_input_since_index!
  end

  def down
    if index_exists?(:issues, :needs_input_since, name: INDEX_NAME)
      remove_index :issues, name: INDEX_NAME, algorithm: :concurrently
    end

    if column_exists?(:issues, :needs_input_since)
      safety_assured { remove_column :issues, :needs_input_since }
    end
  end

  private

  def ensure_needs_input_since_index!
    drop_invalid_needs_input_since_index!
    return if valid_needs_input_since_index?

    safety_assured do
      execute <<~SQL.squish
        CREATE INDEX CONCURRENTLY #{INDEX_NAME}
          ON issues (needs_input_since ASC)
          WHERE paid_state = 'needs_input'
      SQL
    end
  end

  def drop_invalid_needs_input_since_index!
    return unless index_exists?(:issues, :needs_input_since, name: INDEX_NAME)
    return if index_valid?(INDEX_NAME)

    safety_assured do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"
    end
  end

  def valid_needs_input_since_index?
    index_exists?(:issues, :needs_input_since, name: INDEX_NAME) && index_valid?(INDEX_NAME)
  end

  def index_valid?(index_name)
    result = connection.select_value(<<~SQL.squish)
      SELECT pg_index.indisvalid
        FROM pg_class
        INNER JOIN pg_index ON pg_index.indexrelid = pg_class.oid
        INNER JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
       WHERE pg_class.relname = #{connection.quote(index_name)}
         AND pg_namespace.nspname = ANY (current_schemas(false))
       LIMIT 1
    SQL

    ActiveModel::Type::Boolean.new.cast(result)
  end
end
