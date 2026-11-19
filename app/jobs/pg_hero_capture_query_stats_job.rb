# frozen_string_literal: true

class PgHeroCaptureQueryStatsJob < ApplicationJob
  queue_as :metrics
  self.perform_timeout = 30

  # @spec RAILS-CONTROL-PLANE-020 RAILS-CONTROL-PLANE-022
  def perform
    return unless Rails.env.development?

    Development::PgHeroHistory.new.capture_queries
  end
end
