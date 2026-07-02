# frozen_string_literal: true

class AgentRunResourceProfile < ApplicationRecord
  PROFILE_LEVELS = %w[specific runner_goal project account global].freeze
  MIN_SAMPLE_SIZE = 3
  DEFAULT_ESTIMATE_MEMORY_LIMIT_BYTES = 4 * 1024 * 1024 * 1024
  MIN_RECOMMENDED_MEMORY_LIMIT_BYTES = 512 * 1024 * 1024
  SAFETY_MULTIPLIER = 1.2
  OOM_BUMP_MULTIPLIER = 1.25
  OOM_MESSAGE_PATTERN = /container OOM-killed/i

  belongs_to :account, optional: true
  belongs_to :project, optional: true

  validates :profile_level, presence: true, inclusion: { in: PROFILE_LEVELS }
  validates :lookup_key, presence: true, uniqueness: true, length: { maximum: 255 }
  validates :runner_key, length: { maximum: 50 }, allow_blank: true
  validates :goal, inclusion: { in: AgentRun::GOALS }, allow_blank: true
  validates :sample_count, :oom_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :p50_memory_bytes, :p95_memory_bytes, :max_memory_bytes, :recommended_memory_limit_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :validate_profile_scope

  scope :sufficient_samples, -> { where("sample_count >= ?", MIN_SAMPLE_SIZE) }

  def sufficient_samples?
    sample_count >= MIN_SAMPLE_SIZE
  end

  def self.lookup_key_for(profile_level:, account_id: nil, project_id: nil, runner_key: nil, goal: nil)
    case profile_level.to_s
    when "specific"
      "specific:account=#{account_id}:project=#{project_id}:runner=#{runner_key}:goal=#{goal}"
    when "runner_goal"
      "runner_goal:runner=#{runner_key}:goal=#{goal}"
    when "project"
      "project:project=#{project_id}"
    when "account"
      "account:account=#{account_id}"
    when "global"
      "global"
    else
      raise ArgumentError, "Unknown profile level: #{profile_level.inspect}"
    end
  end

  def self.oom_message_pattern
    OOM_MESSAGE_PATTERN
  end

  private

  def validate_profile_scope
    case profile_level
    when "specific"
      errors.add(:account, "must be present") if account_id.blank?
      errors.add(:project, "must be present") if project_id.blank?
      errors.add(:runner_key, "must be present") if runner_key.blank?
      errors.add(:goal, "must be present") if goal.blank?
    when "runner_goal"
      errors.add(:runner_key, "must be present") if runner_key.blank?
      errors.add(:goal, "must be present") if goal.blank?
      errors.add(:account, "must be blank") if account_id.present?
      errors.add(:project, "must be blank") if project_id.present?
    when "project"
      errors.add(:project, "must be present") if project_id.blank?
      errors.add(:account, "must be present") if account_id.blank?
      errors.add(:runner_key, "must be blank") if runner_key.present?
      errors.add(:goal, "must be blank") if goal.present?
    when "account"
      errors.add(:account, "must be present") if account_id.blank?
      errors.add(:project, "must be blank") if project_id.present?
      errors.add(:runner_key, "must be blank") if runner_key.present?
      errors.add(:goal, "must be blank") if goal.present?
    when "global"
      errors.add(:account, "must be blank") if account_id.present?
      errors.add(:project, "must be blank") if project_id.present?
      errors.add(:runner_key, "must be blank") if runner_key.present?
      errors.add(:goal, "must be blank") if goal.present?
    end
  end
end
