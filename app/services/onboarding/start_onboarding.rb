# frozen_string_literal: true

module Onboarding
  # Initializes the onboarding wizard for a newly created account.
  # Creates the onboarding step records and sets trial period.
  #
  # @example
  #   Onboarding::StartOnboarding.call(account: account)
  class StartOnboarding
    STEPS = OnboardingStep::STEPS

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).start
    end

    def start
      return if @account.onboarding_steps.exists?

      ActiveRecord::Base.transaction do
        create_onboarding_steps
        set_trial_period
      end

      @account.onboarding_steps.ordered
    end

    private

    def create_onboarding_steps
      STEPS.each_with_index do |step, index|
        @account.onboarding_steps.create!(
          step: step,
          position: index,
          status: index.zero? ? "in_progress" : "pending"
        )
      end
    end

    def set_trial_period
      return unless @account.trial?
      return if @account.trial_ends_at.present?

      @account.update!(trial_ends_at: Account::TRIAL_DURATION.from_now)
    end
  end
end
