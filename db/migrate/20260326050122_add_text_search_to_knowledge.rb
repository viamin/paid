# frozen_string_literal: true

class AddTextSearchToKnowledge < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    enable_extension "pg_trgm"

    unless column_exists?(:knowledge_chunks, :content_tsvector)
      add_column :knowledge_chunks, :content_tsvector, :tsvector
    end

    execute "DROP TRIGGER IF EXISTS knowledge_chunks_tsvector_update ON knowledge_chunks;"
    execute <<~SQL
      CREATE TRIGGER knowledge_chunks_tsvector_update
      BEFORE INSERT OR UPDATE OF content ON knowledge_chunks
      FOR EACH ROW EXECUTE FUNCTION
      tsvector_update_trigger(content_tsvector, 'pg_catalog.english', content);
    SQL

    # Backfill tsvector for existing rows so full_text_search works immediately after deploy.
    # Uses batched updates via subquery on id (works with UUID primary keys).
    # The GIN index is created AFTER the backfill to avoid costly per-row index updates.
    loop do
      rows_updated = connection.exec_update(<<~SQL, "Backfill knowledge_chunks content_tsvector")
        UPDATE knowledge_chunks
        SET content_tsvector = to_tsvector('pg_catalog.english', coalesce(content, ''))
        WHERE id IN (
          SELECT id FROM knowledge_chunks
          WHERE content_tsvector IS NULL
          LIMIT 10000
        )
      SQL
      break if rows_updated == 0
    end

    unless index_exists?(:knowledge_chunks, :content_tsvector, name: "index_knowledge_chunks_on_content_tsvector")
      add_index :knowledge_chunks, :content_tsvector,
                using: :gin,
                algorithm: :concurrently,
                name: "index_knowledge_chunks_on_content_tsvector"
    end

    unless index_exists?(:knowledge_artifacts, :identifier, name: "index_knowledge_artifacts_on_identifier_trgm")
      add_index :knowledge_artifacts, :identifier,
                using: :gin,
                opclass: :gin_trgm_ops,
                algorithm: :concurrently,
                name: "index_knowledge_artifacts_on_identifier_trgm"
    end
  end

  def down
    execute "DROP TRIGGER IF EXISTS knowledge_chunks_tsvector_update ON knowledge_chunks;"

    remove_index :knowledge_artifacts,
                 name: "index_knowledge_artifacts_on_identifier_trgm",
                 algorithm: :concurrently,
                 if_exists: true

    remove_index :knowledge_chunks,
                 name: "index_knowledge_chunks_on_content_tsvector",
                 algorithm: :concurrently,
                 if_exists: true

    remove_column :knowledge_chunks, :content_tsvector if column_exists?(:knowledge_chunks, :content_tsvector)

    disable_extension "pg_trgm" if extension_enabled?("pg_trgm")
  end
end
