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
end
