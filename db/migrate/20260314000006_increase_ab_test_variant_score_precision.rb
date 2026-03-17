# frozen_string_literal: true

class IncreaseAbTestVariantScorePrecision < ActiveRecord::Migration[8.1]
  def change
    change_column :ab_test_variants, :avg_quality_score, :decimal, precision: 6, scale: 4
    change_column :ab_test_variants, :total_quality_score, :decimal, precision: 12, scale: 4, default: 0, null: false
  end
end
