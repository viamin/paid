# frozen_string_literal: true

module Accounts
  class RecordActivity
    def self.call(...)
      new(...).call
    end

    def initialize(account:, action:, actor: nil, subject: nil, metadata: {})
      @account = account
      @action = action
      @actor = actor
      @subject = subject
      @metadata = metadata
    end

    def call
      account.account_activity_events.create!(
        action: action,
        actor: actor,
        subject: subject,
        metadata: metadata
      )
    end

    private

    attr_reader :account, :action, :actor, :subject, :metadata
  end
end
