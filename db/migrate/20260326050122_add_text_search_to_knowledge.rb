# frozen_string_literal: true

class AddTextSearchToKnowledge < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    enable_extension "pg_trgm"

    add_column :knowledge_chunks, :content_tsvector, :tsvector

    add_index :knowledge_chunks, :content_tsvector,
              using: :gin,
              algorithm: :concurrently,
              name: "index_knowledge_chunks_on_content_tsvector"

    execute <<~SQL
      CREATE TRIGGER knowledge_chunks_tsvector_update
      BEFORE INSERT OR UPDATE OF content ON knowledge_chunks
      FOR EACH ROW EXECUTE FUNCTION
      tsvector_update_trigger(content_tsvector, 'pg_catalog.english', content);
    SQL

    # Backfill tsvector for existing rows so full_text_search works immediately after deploy.
    # Use batched updates over primary-key ranges to avoid a single long-running UPDATE.
    range = select_one(<<~SQL)
      SELECT MIN(id) AS min_id, MAX(id) AS max_id
      FROM knowledge_chunks
      WHERE content_tsvector IS NULL;
    SQL

    if range && range["min_id"] && range["max_id"]
      batch_size = 10_000
      min_id = range["min_id"].to_i
      max_id = range["max_id"].to_i

      (min_id..max_id).step(batch_size) do |start_id|
        end_id = start_id + batch_size

        execute <<~SQL
          UPDATE knowledge_chunks
          SET content_tsvector = to_tsvector('pg_catalog.english', coalesce(content, ''))
          WHERE content_tsvector IS NULL
            AND id >= #{start_id}
            AND id < #{end_id};
        SQL
      end
    end

    add_index :knowledge_artifacts, :identifier,
              using: :gin,
              opclass: :gin_trgm_ops,
              algorithm: :concurrently,
              name: "index_knowledge_artifacts_on_identifier_trgm"
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

    remove_column :knowledge_chunks, :content_tsvector

    disable_extension "pg_trgm"
  end
end
