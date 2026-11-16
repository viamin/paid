# frozen_string_literal: true

# RDR-075 OPT-01 (#4493): retain the catalog selection as an immutable run
# snapshot. It is deliberately a string rather than an enum: catalog growth
# requires no database change and unknown values remain inspectable on retry.
class AddMaintenanceTypeToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :maintenance_type, :string, limit: 100,
      comment: "Raw optimization catalog type selected at maintenance-run start; unmapped values are retained."
  end
end
