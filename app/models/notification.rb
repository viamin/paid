# frozen_string_literal: true

class Notification < ApplicationRecord
  belongs_to :account
  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  NAV_SECTIONS = %w[dashboard projects agent_runs providers runners].freeze

  enum :severity, { info: 0, warning: 1, error: 2 }, validate: true

  validates :source, presence: true
  validates :title, presence: true
  validates :nav_section, inclusion: { in: NAV_SECTIONS }, allow_nil: true
  validate :action_url_is_safe, if: -> { action_url.present? }
  validate :blocking_requires_error_severity

  after_commit :bump_inbox_cache_version, if: :saved_change_to_action_required_membership?

  scope :unread, -> { where(read_at: nil) }
  scope :undismissed, -> { where(dismissed_at: nil) }
  scope :unresolved, -> { where(resolved_at: nil) }
  scope :active, -> { undismissed.unresolved }
  scope :blocking, -> { where(blocking: true) }
  scope :visible, -> { undismissed }
  # @spec NOTIFICATION-SEVERITY-004
  scope :badging, -> { active.unread.where(severity: %i[warning error]) }
  scope :for_nav_section, ->(section) { where(nav_section: section) }
  scope :recent, -> { order(created_at: :desc) }

  def active?
    dismissed_at.nil? && resolved_at.nil?
  end

  private

  # @spec NOTIFICATION-SEVERITY-007
  def blocking_requires_error_severity
    return unless blocking?
    return if error?

    errors.add(:blocking, "requires error severity")
  end

  def saved_change_to_action_required_membership?
    return action_required? if previously_new_record?

    action_required_before_last_save? != action_required?
  end

  def action_required_before_last_save?
    ActiveModel::Type::Boolean.new.cast(attribute_before_last_save("blocking")) &&
      attribute_before_last_save("dismissed_at").nil? &&
      attribute_before_last_save("resolved_at").nil?
  end

  def action_required?
    blocking? && active?
  end

  def bump_inbox_cache_version
    Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end

  def action_url_is_safe
    return if action_url == "/"
    return if action_url.match?(%r{\A(/[^/]|https?://)})

    errors.add(:action_url, "must be a path or HTTP(S) URL")
  end
end
