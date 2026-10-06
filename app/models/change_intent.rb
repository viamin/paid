# frozen_string_literal: true

class ChangeIntent < ApplicationRecord
  class InvalidTransitionError < StandardError; end

  # @spec CHANGE-INTENT-INBOX-001
  # Lifecycle states that keep a Change Intent Record actionable in the Inbox:
  # `draft` is a fresh capture awaiting its first review, `requested_changes`
  # is a draft that already received feedback and is waiting for the draft's
  # editor (chat session, MCP tool, or follow-up issue enhancement) to revise
  # before the next approve pass.
  PENDING_REVIEW_STATUSES = %w[draft requested_changes].freeze

  STATUSES = (PENDING_REVIEW_STATUSES + %w[active superseded reverted]).freeze
  MUTABLE_FIELDS = %w[
    status
    superseded_by_id
    updated_at
    requested_changes_at
    requested_changes_reason
  ].freeze
  REVISION_FIELDS = %w[
    title
    intent
    behavior
    constraints
    decisions_made
    chat_session
    chat_session_id
  ].freeze

  belongs_to :project
  belongs_to :chat_session, optional: true
  belongs_to :issue, optional: true
  belongs_to :superseded_by, class_name: "ChangeIntent", optional: true

  has_many :supersedes, class_name: "ChangeIntent", foreign_key: :superseded_by_id,
    inverse_of: :superseded_by, dependent: :nullify

  validate :enforce_immutability, on: :update

  validates :title, presence: true, length: { maximum: 500 }
  validates :intent, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :chat_session_belongs_to_same_project, if: -> { chat_session.present? }
  validate :issue_belongs_to_same_project, if: -> { issue.present? }
  validate :superseded_by_belongs_to_same_project, if: -> { superseded_by.present? }
  validate :superseded_by_is_not_self

  # @spec CHANGE-INTENT-INBOX-001
  # Status changes into or out of the Inbox "pending review" lane must
  # invalidate the cached nav badge so the count tracks the new state.
  # Also bumps on initial create so a freshly recorded draft CIR (chat-driven
  # or issue-enhancement-driven) appears in the cached count without
  # waiting for the 90-second TTL to roll over.
  after_commit :bump_inbox_cache_version, if: :inbox_pending_review_state_changed?

  scope :active, -> { where(status: "active") }
  scope :draft, -> { where(status: "draft") }
  scope :requested_changes, -> { where(status: "requested_changes") }
  scope :pending_review, -> { where(status: PENDING_REVIEW_STATUSES) }
  scope :for_project, ->(project) { where(project: project) }
  scope :by_status, ->(status) { where(status: status) }

  def activate!
    with_lock do
      reload
      unless status.in?(PENDING_REVIEW_STATUSES)
        raise InvalidTransitionError, "cannot activate from #{status}"
      end

      update!(status: "active", requested_changes_at: nil, requested_changes_reason: nil)
    end
  end

  def supersede!(new_record)
    raise ArgumentError, "cannot supersede with itself" if new_record == self

    with_lock do
      reload
      unless status.in?(%w[draft active])
        raise InvalidTransitionError, "cannot supersede from #{status}"
      end

      update!(status: "superseded", superseded_by: new_record)
    end
  end

  def revert!
    with_lock do
      reload
      unless status.in?(%w[draft active])
        raise InvalidTransitionError, "cannot revert from #{status}"
      end

      update!(status: "reverted")
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  # Transitions a draft into "requested changes", stamping the review
  # timestamp and operator reason so the inbox entry keeps explaining what
  # the operator wants changed. Re-entering the lane from a prior
  # `requested_changes` round overwrites the prior review metadata, matching
  # the contract that the latest review reason is the one the inbox shows.
  def request_changes!(reason:)
    with_lock do
      reload
      unless status.in?(PENDING_REVIEW_STATUSES)
        raise InvalidTransitionError, "cannot request changes from #{status}"
      end

      update!(
        status: "requested_changes",
        requested_changes_at: Time.current,
        requested_changes_reason: reason.to_s.strip.presence
      )
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  # A new proposal supersedes the feedback on a pending draft, so return it to
  # the ordinary draft lane and clear the review metadata that it addressed.
  def revise!(attributes)
    with_lock do
      reload
      unless pending_review?
        raise InvalidTransitionError, "cannot revise from #{status}"
      end

      update!(attributes.stringify_keys.slice(*REVISION_FIELDS).merge(
        status: "draft",
        requested_changes_at: nil,
        requested_changes_reason: nil
      ))
    end
  end

  def pending_review?
    status.in?(PENDING_REVIEW_STATUSES)
  end

  def requested_changes?
    status == "requested_changes"
  end

  private

  def chat_session_belongs_to_same_project
    direct_match = chat_session.project_id == project_id
    referenced_match = chat_session.projects.where(id: project_id).exists?
    return if direct_match || referenced_match

    errors.add(:chat_session, "must belong to the same project")
  end

  def issue_belongs_to_same_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def superseded_by_belongs_to_same_project
    return if superseded_by.project_id == project_id

    errors.add(:superseded_by, "must belong to the same project")
  end

  def superseded_by_is_not_self
    return unless persisted? && superseded_by_id == id

    errors.add(:superseded_by, "cannot reference itself")
  end

  def enforce_immutability
    immutable_changes = changed - MUTABLE_FIELDS
    return if immutable_changes.empty? || revising_pending_record?(immutable_changes)

    immutable_changes.each do |field|
      errors.add(field, "is immutable after creation")
    end
  end

  def inbox_pending_review_state_changed?
    return true if destroyed? && status.in?(PENDING_REVIEW_STATUSES)
    return true if previously_new_record? && status.in?(PENDING_REVIEW_STATUSES)

    saved_change_to_status? && (
      saved_change_to_status.any? { |value| PENDING_REVIEW_STATUSES.include?(value) }
    )
  end

  def revising_pending_record?(changes)
    pending_review? && changes.all? { |field| REVISION_FIELDS.include?(field) }
  end

  def bump_inbox_cache_version
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end
end
