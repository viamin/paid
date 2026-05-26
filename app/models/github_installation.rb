# frozen_string_literal: true

class GithubInstallation < ApplicationRecord
  include TenantScoped

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
end
