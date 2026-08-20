# frozen_string_literal: true

class AddRuntimeImageMetadataToContainerPoolEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :container_pool_entries, :runtime_image_metadata, :jsonb,
      comment: "Warm-time immutable runtime image selection (RDR-059) for the warmed container; copied onto the claiming run."
  end
end
