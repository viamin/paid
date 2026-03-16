# frozen_string_literal: true

class AddUpdatedAtToQualityMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :quality_metrics, :updated_at, :datetime
  end
end
