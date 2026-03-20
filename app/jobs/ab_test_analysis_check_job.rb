# frozen_string_literal: true

# Cron job that enqueues analysis for each running A/B test with sufficient samples.
class AbTestAnalysisCheckJob < ApplicationJob
  queue_as :default

  def perform
    AbTest.running.find_each do |ab_test|
      next unless ab_test.sufficient_samples?

      AbTestAnalysisJob.perform_later(ab_test.id)
    end
  end
end
