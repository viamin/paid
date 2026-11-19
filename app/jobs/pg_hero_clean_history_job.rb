# frozen_string_literal: true

class PgHeroCleanHistoryJob < ApplicationJob
  queue_as :metrics
  self.perform_timeout = 30

  # @spec RAILS-CONTROL-PLANE-021
  def perform
    return unless Rails.env.development?

    Development::PgHeroHistory.new.clean_history
  end
end
