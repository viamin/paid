# frozen_string_literal: true

class AddLogidzeToAgentImages < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:agent_images, :log_data)
      add_column :agent_images, :log_data, :jsonb, comment: "Logidze change history for image lifecycle transitions and provenance/metadata edits."
    end

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_agent_images, on: :agent_images
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_agent_images" on "agent_images";
        SQL
      end
    end
  end
end
