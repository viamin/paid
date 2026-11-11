# frozen_string_literal: true

module Containers
  # Issues a short-lived identity for one runner's managed subscription material.
  class StandaloneTextCredential
    PURPOSE = "standalone-text-credential"

    def self.issue(account:, runner:, expires_in:, env_keys: [])
      verifier.generate({ account_id: account.id, runner_id: runner.id, env_keys: env_keys },
        expires_in: expires_in, purpose: PURPOSE)
    end

    def self.verify(token)
      verifier.verified(token, purpose: PURPOSE)&.symbolize_keys
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :verifier
  end
end
