# frozen_string_literal: true

# Server-side claim tying a freshly-returned GitHub App installation to a
# Paid account.
#
# The browser-side install callback proves the user initiated the flow, but
# the GitHub `installation` webhook is the only signal that proves which
# `(installation_id, account_id)` pairing the customer actually completed.
# For a first-time install into a brand-new org neither the existing project
# owner match nor the prior-installation check can resolve the account from
# the webhook payload alone — we have to remember the binding from when the
# user clicked "Install" and persist it on the server.
#
# Lifecycle:
#   1. The user clicks "Install" → controller mints CSRF state → user is
#      redirected to GitHub.
#   2. The user completes the install on GitHub → GitHub redirects to the
#      callback with `installation_id` + `setup_action` + `state`.
#   3. The controller verifies the CSRF state, then upserts a
#      `PendingInstallClaim` with `(installation_id, account_id,
#      source=callback_with_state, expires_at=now+TTL)`. The CSRF state is
#      the only thing tying the user to the account; the claim is what
#      survives the round-trip and lets the webhook finalize the binding.
#   4. The signed `installation` webhook fires. `AccountResolver` looks up
#      the claim by `installation_id` and binds the `GithubInstallation`
#      row to the claimed account.
#   5. Stale claims (past `expires_at`) are skipped — a long-lived claim
#      must never authorize a binding the user did not initiate recently.
class PendingInstallClaim < ApplicationRecord
  include TenantScoped

  SOURCES = %w[callback_with_state operator_setup].freeze
  TTL = 1.hour

  belongs_to :account

  validates :github_installation_id, presence: true,
                                      uniqueness: { scope: :account_id }
  validates :source, inclusion: { in: SOURCES }
  validates :expires_at, presence: true

  scope :active, -> { where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }

  def expired?
    expires_at <= Time.current
  end

  def self.upsert_for_callback!(account:, installation_id:, source:, state_token: nil)
    return if installation_id.blank? || account.blank?

    TenantContext.with_system_access do
      record = find_or_initialize_by(
        account_id: account.id,
        github_installation_id: installation_id
      )
      record.source = source
      record.state_token = state_token if state_token.present?
      record.expires_at = Time.current + TTL
      record.save!
      record
    end
  end

  def self.find_active(installation_id)
    return nil if installation_id.blank?

    TenantContext.with_system_access do
      active.where(github_installation_id: installation_id).order(created_at: :desc).first
    end
  end
end
