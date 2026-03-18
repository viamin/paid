# frozen_string_literal: true

class AddCachedAnalysisToAbTests < ActiveRecord::Migration[8.1]
  def change
    add_column :ab_tests, :cached_analysis, :jsonb
    add_column :ab_tests, :analysis_samples_key, :string
  end
end
