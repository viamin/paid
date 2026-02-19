# frozen_string_literal: true

class GithubToken < ApplicationRecord
  # GitHub token format patterns
  # Classic PAT: ghp_xxxx (40 chars after prefix)
  # Fine-grained PAT: github_pat_xxxx
  # OAuth: gho_xxxx
  # User-to-server: ghu_xxxx
  # Server-to-server: ghs_xxxx
  # Refresh token: ghr_xxxx
  GITHUB_TOKEN_PATTERN = /\A(ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|gh[ours]_[A-Za-z0-9]{36,})\z/
  VALIDATION_STATUSES = %w[pending validating validated failed].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  has_many :projects, dependent: :restrict_with_error

  encrypts :token

  validates :name, presence: true, uniqueness: { scope: :account_id }
  validates :token, presence: true
  validates :validation_status, inclusion: { in: VALIDATION_STATUSES }
  validate :token_format_valid, if: -> { token.present? }
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :expired, -> { where.not(expires_at: nil).where("expires_at <= ?", Time.current) }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :pending_validation, -> { where(validation_status: "pending") }
  scope :validated, -> { where(validation_status: "validated") }

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def validation_pending?
    validation_status == "pending"
  end

  def validating?
    validation_status == "validating"
  end

  def validated?
    validation_status == "validated"
  end

  def validation_failed?
    validation_status == "failed"
  end

  def mark_validating!
    update!(validation_status: "validating", validation_error: nil)
  end

  def mark_validated!
    update!(validation_status: "validated", validation_error: nil)
  end

  def mark_validation_failed!(error_message)
    update!(validation_status: "failed", validation_error: error_message)
  end

  # Whether this token is a fine-grained personal access token.
  def fine_grained?
    token.start_with?("github_pat_")
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  # Returns a GithubClient instance configured with this token.
  # Caches the client instance for the lifetime of the record.
  #
  # @return [GithubClient] GitHub API client
  def client
    @client ||= GithubClient.new(token: token)
  end

  # Validates the token against GitHub API and updates scopes.
  # Also touches last_used_at on successful validation.
  #
  # @return [Hash] User info with :login, :id, :name, :email, :scopes keys
  # @raise [GithubClient::AuthenticationError] if the token is invalid
  def validate_with_github!
    result = client.validate_token
    update!(scopes: result[:scopes])
    touch_last_used!
    sync_repositories!
    result
  end

  # Fetches accessible repositories from GitHub and caches them.
  # For fine-grained PATs, probes write access to filter down to repos
  # the token was actually granted access to (GitHub's read APIs report
  # user permissions, not token permissions).
  #
  # @return [Array<Hash>] Cached repository data
  # @raise [GithubClient::Error] on API failures
  def sync_repositories!
    repos = client.repositories
    repos = repos.select { |r| client.write_accessible?(r.full_name) } if fine_grained?
    repo_data = repos.map { |r| serialize_repository(r) }
    update!(accessible_repositories: repo_data, repositories_synced_at: Time.current)
    touch_last_used!
    repo_data
  end

  # Returns cached repositories, syncing if stale.
  #
  # @param max_age [ActiveSupport::Duration] Maximum cache age before re-syncing
  # @return [Array<Hash>] Cached repository data
  def cached_repositories(max_age: 1.hour)
    repositories_stale?(max_age) ? sync_repositories! : accessible_repositories
  end

  private

  def token_format_valid
    return if token.match?(GITHUB_TOKEN_PATTERN)

    errors.add(:token, "must be a valid GitHub token format")
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end

  def serialize_repository(repo)
    {
      "id" => repo.id,
      "full_name" => repo.full_name,
      "name" => repo.name,
      "owner" => repo.full_name.split("/").first,
      "default_branch" => repo.default_branch,
      "private" => repo.private
    }
  end

  def repositories_stale?(max_age)
    repositories_synced_at.nil? || repositories_synced_at < max_age.ago
  end
end
