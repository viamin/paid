# frozen_string_literal: true

# @spec RAILS-CONTROL-PLANE-036
class AddAssessmentToPgHeroOverviewFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :pghero_overview_findings, :assessment, :jsonb, null: false, default: {}
  end
end
