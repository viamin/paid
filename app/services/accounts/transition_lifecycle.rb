# frozen_string_literal: true

module Accounts
  class TransitionLifecycle
    TRANSITIONS = {
      "suspend" => :suspend!,
      "reactivate" => :reactivate!,
      "deactivate" => :deactivate!
    }.freeze
    ACTIVITY_ACTIONS = {
      "suspend" => "lifecycle.suspended",
      "reactivate" => "lifecycle.reactivated",
      "deactivate" => "lifecycle.deactivated"
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(account:, actor:, transition:)
      @account = account
      @actor = actor
      @transition = transition.to_s
    end

    def call
      method_name = TRANSITIONS[transition]
      raise AdministrationError, "Unsupported lifecycle transition." unless method_name

      account.public_send(method_name)

      Accounts::RecordActivity.call(
        account: account,
        actor: actor,
        action: ACTIVITY_ACTIONS.fetch(transition),
        subject: account
      )
    end

    private

    attr_reader :account, :actor, :transition
  end
end
