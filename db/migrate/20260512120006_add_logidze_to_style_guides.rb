# frozen_string_literal: true

class AddLogidzeToStyleGuides < ActiveRecord::Migration[8.1]
  def change
    add_column :style_guides, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_style_guides, on: :style_guides
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_style_guides" on "style_guides";
        SQL
      end
    end
  end
end
