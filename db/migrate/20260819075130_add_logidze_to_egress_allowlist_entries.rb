# frozen_string_literal: true

class AddLogidzeToEgressAllowlistEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :egress_allowlist_entries, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_egress_allowlist_entries, on: :egress_allowlist_entries
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_egress_allowlist_entries" on "egress_allowlist_entries";
        SQL
      end
    end
  end
end
