# frozen_string_literal: true

module Onboarding
  # Skips an onboarding step and advances to the next one.
  #
  # @example
  #   Onboarding::SkipStep.call(account: account, step: "configure_defaults")
  class SkipStep
    SKIPPABLE_STEPS = %w[configure_defaults].freeze

    def initialize(account:, step:)
      @account = account
      @step = step
    end

    def self.call(...)
      new(...).skip
    end

    def skip
      validate!
      onboarding_step = @account.onboarding_steps.find_by!(step: @step)

      ActiveRecord::Base.transaction do
        onboarding_step.skip!
        advance_to_next_step(onboarding_step)
        finalize_if_complete
      end

      onboarding_step
    end

    private

    def validate!
      raise ArgumentError, "step '#{@step}' cannot be skipped" unless SKIPPABLE_STEPS.include?(@step)
    end

    def advance_to_next_step(skipped_step)
      next_step = @account.onboarding_steps
        .where("position > ?", skipped_step.position)
        .ordered
        .find_by(status: "pending")

      next_step&.mark_in_progress!
    end

    def finalize_if_complete
      remaining = @account.onboarding_steps.where(status: %w[pending in_progress])
      return if remaining.exists?

      @account.update!(onboarding_completed_at: Time.current)
    end
  end
end
