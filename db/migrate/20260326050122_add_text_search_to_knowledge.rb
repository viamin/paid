# frozen_string_literal: true

class AddTextSearchToKnowledge < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"

    add_column :knowledge_chunks, :content_tsvector, :tsvector

    add_index :knowledge_chunks, :content_tsvector, using: :gin,
              name: "index_knowledge_chunks_on_content_tsvector"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE TRIGGER knowledge_chunks_tsvector_update
          BEFORE INSERT OR UPDATE OF content ON knowledge_chunks
          FOR EACH ROW EXECUTE FUNCTION
          tsvector_update_trigger(content_tsvector, 'pg_catalog.english', content);
        SQL
      end
      dir.down do
        execute "DROP TRIGGER IF EXISTS knowledge_chunks_tsvector_update ON knowledge_chunks;"
      end
    end

    add_index :knowledge_artifacts, :identifier, using: :gin, opclass: :gin_trgm_ops,
              name: "index_knowledge_artifacts_on_identifier_trgm"
  end
end
