# frozen_string_literal: true

class AddLogidzeToPrTemplates < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_templates, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_pr_templates, on: :pr_templates
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_pr_templates" on "pr_templates";
        SQL
      end
    end
  end
end
