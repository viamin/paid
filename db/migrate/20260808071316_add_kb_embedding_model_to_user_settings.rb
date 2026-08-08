# frozen_string_literal: true

# Adds user-configurable embedding model and dimension overrides to
# user_settings, sourced from the LlmModel provider catalog. The defaults
# preserve the previous hardcoded text-embedding-3-large / 3072 vector size so
# existing knowledge bases continue to work without re-embedding.
class AddKbEmbeddingModelToUserSettings < ActiveRecord::Migration[8.1]
  DEFAULT_EMBEDDING_MODEL = "text-embedding-3-large"
  DEFAULT_EMBEDDING_DIMENSIONS = 3_072

  def change
    unless column_exists?(:user_settings, :kb_embedding_model)
      add_column :user_settings, :kb_embedding_model, :string,
        default: DEFAULT_EMBEDDING_MODEL, null: false,
        comment: "User-configurable embedding model id. Defaults to text-embedding-3-large; users may pick any model from the provider catalog the configured embedding runner serves."
    end

    unless column_exists?(:user_settings, :kb_embedding_dimensions)
      add_column :user_settings, :kb_embedding_dimensions, :integer,
        default: DEFAULT_EMBEDDING_DIMENSIONS, null: false,
        comment: "Vector dimensions to request from the embedding model. Must match what the chosen kb_embedding_model emits; changing this on a populated knowledge base requires re-embedding."
    end
  end
end
