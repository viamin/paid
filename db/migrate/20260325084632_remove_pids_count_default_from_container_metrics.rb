# frozen_string_literal: true

class RemovePidsCountDefaultFromContainerMetrics < ActiveRecord::Migration[8.1]
  def change
    change_column_default :container_metrics, :pids_count, from: 0, to: nil
  end
end
