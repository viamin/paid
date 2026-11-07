# frozen_string_literal: true

# A grouped material-question checkpoint for one work item (RDR-080 intent
# checkpoint): related material product questions presented with their
# recommendation, alternatives, consequences, affected scope, and evidence.
# A human settlement records immutable answers bound to the design and
# acceptance revision current at settlement, so downstream boundaries can
# honor the settled answer instead of re-asking the question.
#
# Mutation of terminal checkpoints (settled/rejected) is rejected by both
# this model's callbacks and the database-level triggers installed by
# CreateIntentCheckpoints, including `update_all`, `delete_all`, and direct
# SQL.
#
# @spec PROJECT-DELEGATION-002
class IntentCheckpoint < ApplicationRecord
  STATUSES = %w[pending settled rejected superseded].freeze
  TERMINAL_STATUSES = %w[settled rejected].freeze
  DISPOSITIONS = %w[settled amended rejected].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :feature_intent, optional: true
  belongs_to :settled_by, class_name: "User", optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :disposition, inclusion: { in: DISPOSITIONS }, allow_nil: true
  validate :groups_are_presentable
  validate :settlement_is_bound, if: -> { terminal? }

  before_update :prevent_terminal_mutation
  before_destroy :prevent_terminal_mutation

  scope :pending, -> { where(status: "pending") }
  scope :settled, -> { where(status: "settled") }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :latest_first, -> { order(id: :desc) }

  def terminal? = status.in?(TERMINAL_STATUSES)
  def pending? = status == "pending"

  def group_keys = groups.map { |group| group["key"] }

  def group_for(key) = groups.find { |group| group["key"] == key.to_s }

  def covers_question?(question)
    text = question.to_s.strip
    return false if text.empty?

    groups.any? { |group| Array(group["questions"]).map(&:to_s).include?(text) }
  end

  def answer_for(key)
    answers.to_h[key.to_s]
  end

  private

  # Every group presents the question(s), recommendation, alternatives,
  # consequences, affected scope, and evidence (PROJECT-DELEGATION-002).
  def groups_are_presentable
    errors.add(:groups, "must be an array of question groups") unless groups.is_a?(Array)
    return unless groups.is_a?(Array)

    keys = groups.filter_map do |group|
      presentable_group_errors(group)
      group["key"] if group.is_a?(Hash)
    end
    errors.add(:groups, "group keys must be unique") if keys.size != keys.uniq.size
  end

  def presentable_group_errors(group)
    unless group.is_a?(Hash)
      errors.add(:groups, "each group must be an object")
      return
    end

    errors.add(:groups, "each group needs a key") if group["key"].to_s.strip.empty?
    errors.add(:groups, "each group needs an affected scope") if group["affected_scope"].to_s.strip.empty?
    errors.add(:groups, "each group needs a recommendation") if group["recommendation"].to_s.strip.empty?
    return if group["questions"].is_a?(Array) && group["questions"].any?(&:present?)

    errors.add(:groups, "each group needs at least one question")
  end

  # A terminal settlement is immutable evidence: it must carry the human's
  # answers and the exact revisions they were bound to.
  def settlement_is_bound
    errors.add(:disposition, "must be recorded") if disposition.blank?
    validate_settlement_answers unless disposition == "rejected"
    %i[design_revision acceptance_revision settled_by settled_at].each do |binding|
      errors.add(binding, "must be recorded") if public_send(binding).blank?
    end
  end

  def validate_settlement_answers
    answered = answers.is_a?(Hash) ? answers.transform_keys(&:to_s) : {}
    return if group_keys.all? { |key| answered[key].present? }

    errors.add(:answers, "must record an answer for every group")
  end

  def prevent_terminal_mutation
    return unless status_was.in?(TERMINAL_STATUSES)

    raise ActiveRecord::ReadOnlyRecord, "intent checkpoint settlements are immutable"
  end
end
