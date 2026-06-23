# frozen_string_literal: true

class GithubInstallation < ApplicationRecord
  include TenantScoped

  REPOSITORIES_CACHE_MAX_AGE = 1.hour
  REPOSITORIES_SYNC_FAILURE_BACKOFF = 5.minutes

  belongs_to :account
  has_many :projects, dependent: :restrict_with_error

  validates :github_installation_id, presence: true,
                                     uniqueness: { scope: :account_id }

  scope :active, -> { where(suspended_at: nil, revoked_at: nil) }
  scope :suspended, -> { where.not(suspended_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  def active?
    suspended_at.nil? && revoked_at.nil?
  end

  def display_name
    return "#{account_login} (#{github_installation_id})" if account_login.present?

    "Installation #{github_installation_id}"
  end

  def suspended?
    suspended_at.present?
  end

  def revoked?
    revoked_at.present?
  end

  def covers_repository?(repo_full_name)
    owner, repo = repo_full_name.to_s.split("/", 2)
    return false if owner.blank? || repo.blank? || !active?
    return true if repository_selection == "all" && account_login.casecmp?(owner)

    Array(accessible_repositories).any? do |repository|
      repository.fetch("full_name", "").casecmp?(repo_full_name)
    end
  end

  def cached_repositories(max_age: REPOSITORIES_CACHE_MAX_AGE)
    return accessible_repositories unless should_sync_repositories?(max_age)

    sync_repositories!
  rescue Github::InstallationRepositories::Error => e
    Rails.logger.warn(
      message: "github_installation.repositories_sync_failed",
      github_installation_id: id,
      error: e.message
    )
    Rails.cache.write(repositories_sync_failure_cache_key, true, expires_in: REPOSITORIES_SYNC_FAILURE_BACKOFF)
    accessible_repositories
  end

  def sync_repositories!
    repositories = Github::InstallationRepositories.fetch(installation_id: github_installation_id)
    update!(accessible_repositories: repositories, repositories_synced_at: Time.current)
    repositories
  end

  private

  def should_sync_repositories?(max_age)
    active? &&
      (repositories_synced_at.nil? || repositories_synced_at < max_age.ago) &&
      !Rails.cache.exist?(repositories_sync_failure_cache_key) &&
      Github::AppRegistry.configured?
  end

  def repositories_sync_failure_cache_key
    "github_installation:#{id || github_installation_id}:repositories_sync_failed"
  end
end
