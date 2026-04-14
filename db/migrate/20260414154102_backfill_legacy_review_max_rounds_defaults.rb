# frozen_string_literal: true

class BackfillLegacyReviewMaxRoundsDefaults < ActiveRecord::Migration[8.1]
  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  LEGACY_DEFAULT_MAX_REVIEW_ROUNDS = {
    "copilot" => 2,
    "paid_agent" => 3,
    "codex" => 2
  }.freeze
  NEW_DEFAULT_MAX_REVIEW_ROUNDS = 15

  def up
    MigrationProject.unscoped.find_each do |project|
      review_settings = normalized_review_settings(project.review_settings)
      next if review_settings.nil?

      methods = review_settings["methods"]
      next unless methods.is_a?(Hash)

      changed = false
      LEGACY_DEFAULT_MAX_REVIEW_ROUNDS.each do |method_name, legacy_rounds|
        termination = methods.dig(method_name, "termination")
        next unless termination.is_a?(Hash)
        next unless termination["max_review_rounds"] == legacy_rounds

        termination["max_review_rounds"] = NEW_DEFAULT_MAX_REVIEW_ROUNDS
        changed = true
      end

      next unless changed

      project.update_columns(review_settings: review_settings, updated_at: Time.current)
    end
  end

  def down; end

  private

  def normalized_review_settings(value)
    return unless value.is_a?(Hash)

    value.deep_stringify_keys
  end
end
