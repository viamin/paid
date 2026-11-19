# frozen_string_literal: true

class PgHeroCaptureSpaceStatsJob < ApplicationJob
  queue_as :metrics

  # @spec RAILS-CONTROL-PLANE-021
  def perform
    return unless Rails.env.development?

    Development::PgHeroHistory.new.capture_space
  end
end
