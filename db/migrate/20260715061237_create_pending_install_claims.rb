# frozen_string_literal: true

class CreatePendingInstallClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_install_claims,
      comment: "Server-side claims tying a freshly-returned GitHub App installation to a Paid account, " \
        "so the signed `installation` webhook can finalize the GithubInstallation row for a first-time " \
        "install into a brand-new org where the existing signals (project owner match, prior installation " \
        "row) cannot resolve the account." do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint :github_installation_id, null: false,
        comment: "GitHub installation ID returned by the post-install redirect (callback or setup_url)"
      t.string :source, null: false,
        comment: "How the claim was created: callback_with_state (user-initiated SaaS flow with verified " \
          "CSRF state), operator_setup (self-hosted setup_url redirect, operator-authenticated)"
      t.string :state_token, null: true,
        comment: "Opaque CSRF state token tied to the user's session at install time; included for " \
          "audit / forensic value, not used as a binding signal in itself"
      t.datetime :expires_at, null: false,
        comment: "When this claim becomes invalid; a stale claim must never authorize a binding"

      t.timestamps
    end

    add_index :pending_install_claims, :github_installation_id,
      name: "index_pending_install_claims_on_github_installation_id"
    add_index :pending_install_claims, [ :account_id, :github_installation_id ], unique: true,
      name: "idx_pending_install_claims_on_account_installation"
    add_index :pending_install_claims, :expires_at,
      name: "index_pending_install_claims_on_expires_at"
  end
end
