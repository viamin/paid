# frozen_string_literal: true

class AddRedactionScannedAtToKnowledgeChunks < ActiveRecord::Migration[8.1]
  def change
    add_column :knowledge_chunks, :redaction_scanned_at, :datetime
  end
end
