# frozen_string_literal: true

class AddEvidenceSourceToMaintenanceFindingOccurrences < ActiveRecord::Migration[8.1]
  def change
    add_column :maintenance_finding_occurrences, :evidence_source, :string, limit: 16, null: false, default: "agent"
    change_column_default :maintenance_finding_occurrences, :evidence_source, from: "agent", to: nil
  end
end
