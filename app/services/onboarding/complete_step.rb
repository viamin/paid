# frozen_string_literal: true

module Onboarding
  # Marks an onboarding step as completed and advances to the next step.
  # When all steps are done, marks the account onboarding as complete.
  #
  # @example
  #   Onboarding::CompleteStep.call(account: account, step: "github_token", metadata: { token_id: 1 })
  class CompleteStep
    def initialize(account:, step:, metadata: {})
      @account = account
      @step = step
      @metadata = metadata
    end

    def self.call(...)
      new(...).complete
    end

    def complete
      onboarding_step = @account.onboarding_steps.find_by!(step: @step)

      ActiveRecord::Base.transaction do
        onboarding_step.complete!(@metadata)
        advance_to_next_step(onboarding_step)
        finalize_if_complete
      end

      onboarding_step
    end

    private

    def advance_to_next_step(completed_step)
      next_step = @account.onboarding_steps
        .where("position > ?", completed_step.position)
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
