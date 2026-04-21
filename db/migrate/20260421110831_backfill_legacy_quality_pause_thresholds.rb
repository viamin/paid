# frozen_string_literal: true

class BackfillLegacyQualityPauseThresholds < ActiveRecord::Migration[8.1]
  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  class MigrationQualityThreshold < ApplicationRecord
    self.table_name = "quality_thresholds"
  end

  METRIC_TYPE = "composite_score"
  GOAL_TYPE = "create_pr"

  def up
    MigrationProject.unscoped.where("review_settings ? 'quality_pause_threshold'").find_each do |project|
      min_value = legacy_threshold(project.review_settings)
      next if min_value.nil?
      next if threshold_exists?(project)

      MigrationQualityThreshold.create!(
        account_id: project.account_id,
        project_id: project.id,
        metric_type: METRIC_TYPE,
        goal_type: GOAL_TYPE,
        min_value: min_value,
        enabled: true
      )
    end
  end

  def down; end

  private

  def legacy_threshold(review_settings)
    return unless review_settings.is_a?(Hash)

    value = review_settings["quality_pause_threshold"]
    threshold = BigDecimal(value.to_s)
    threshold if threshold.between?(0, 1)
  rescue ArgumentError
    nil
  end

  def threshold_exists?(project)
    MigrationQualityThreshold.exists?(
      project_id: project.id,
      metric_type: METRIC_TYPE,
      goal_type: GOAL_TYPE
    )
  end
end
