# frozen_string_literal: true

class AddConfidenceDeliverySnapshotToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:agent_runs, :confidence_delivery_snapshot)

    add_column :agent_runs, :confidence_delivery_snapshot, :jsonb, null: false, default: {},
      comment: "Immutable confidence-delivery scope, evidence, thresholds, and merged-design baseline admitted for this run."
  end

  def down
    remove_column :agent_runs, :confidence_delivery_snapshot if column_exists?(:agent_runs, :confidence_delivery_snapshot)
  end
end
