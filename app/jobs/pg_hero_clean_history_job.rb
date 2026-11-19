# frozen_string_literal: true

class PgHeroCleanHistoryJob < ApplicationJob
  queue_as :metrics

  # @spec RAILS-CONTROL-PLANE-021
  def perform
    return unless Rails.env.development?

    Development::PgHeroHistory.new.clean_history
  end
end
