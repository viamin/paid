# frozen_string_literal: true

class QualityThreshold < ApplicationRecord
  DEFAULT_WINDOW_SIZE = 5
  DEFAULT_MIN_SAMPLE_SIZE = 3
  METRIC_TYPES = %w[composite_score pr_created ci_passed pr_merged iterations lint_clean
                    tests_pass
                    review_comment_count agent_rerun_count issue_created
                    reaction_score review_posted review_score comment_posted
                    author_replied question_count].freeze
  GOAL_TYPES = AgentRun::GOALS.freeze
  DEFAULT_DEFINITIONS = [
    { "metric_type" => "composite_score", "goal_type" => "create_pr", "min_value" => 0.5 }
  ].freeze

  attr_accessor :source_scope

  belongs_to :account
  belongs_to :project, optional: true

  before_validation :assign_account_from_project

  validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
  validates :goal_type, presence: true, inclusion: { in: GOAL_TYPES }
  validates :min_value, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validate :project_belongs_to_account
  validate :unique_scope

  scope :account_defaults, -> { where(project_id: nil) }
  scope :project_overrides, -> { where.not(project_id: nil) }
  scope :enabled, -> { where(enabled: true) }
  scope :for_goal, ->(goal_type) { where(goal_type: goal_type) }
  scope :for_metric, ->(metric_type) { where(metric_type: metric_type) }

  def self.effective_for(project:, goal_type: nil, include_disabled: false)
    thresholds = default_thresholds(project.account)
    apply_overrides(thresholds, account_thresholds(project.account), "account")
    apply_overrides(thresholds, project_thresholds(project), "project")
    thresholds.values.select { |threshold| (include_disabled || threshold.enabled?) && goal_matches?(threshold, goal_type) }
  end

  def self.configurable_for(project:)
    thresholds = configurable_thresholds(project.account)
    apply_overrides(thresholds, account_thresholds(project.account), "account")
    apply_overrides(thresholds, project_thresholds(project), "project")
    thresholds.values.sort_by { |threshold| [ threshold.goal_type, threshold.metric_type ] }
  end

  def self.override_for(project:, metric_type:, goal_type:)
    project.quality_thresholds.find_by(metric_type: metric_type, goal_type: goal_type)
  end

  def self.metric_label(metric_type)
    QualityMetrics::DashboardStats::METRIC_DISPLAY.dig(metric_type, :name) || metric_type.humanize
  end

  def breached?(value)
    value.present? && value.to_f < min_value.to_f
  end

  def inherited?
    source_scope != "project"
  end

  def default?
    source_scope == "default"
  end

  private_class_method def self.default_thresholds(account)
    DEFAULT_DEFINITIONS.index_with do |definition|
      new(definition.merge("account" => account, "enabled" => true)).tap do |threshold|
        threshold.source_scope = "default"
      end
    end.transform_keys { |definition| key_for(definition.fetch("metric_type"), definition.fetch("goal_type")) }
  end

  private_class_method def self.configurable_thresholds(account)
    (DEFAULT_DEFINITIONS + composite_score_definitions + supported_metric_definitions)
      .uniq { |definition| key_for(definition.fetch("metric_type"), definition.fetch("goal_type")) }
      .index_with do |definition|
        built_in = DEFAULT_DEFINITIONS.include?(definition)
        new(definition.merge("account" => account, "enabled" => built_in)).tap do |threshold|
          threshold.source_scope = built_in ? "default" : "supported"
        end
      end.transform_keys { |definition| key_for(definition.fetch("metric_type"), definition.fetch("goal_type")) }
  end

  private_class_method def self.composite_score_definitions
    GOAL_TYPES.map do |goal_type|
      { "metric_type" => "composite_score", "goal_type" => goal_type, "min_value" => 0.5 }
    end
  end

  private_class_method def self.supported_metric_definitions
    QualityMetrics::DashboardStats::METRIC_DISPLAY.flat_map do |metric_type, display|
      next [] unless METRIC_TYPES.include?(metric_type)

      display.fetch(:collected_for).map do |goal_type|
        { "metric_type" => metric_type, "goal_type" => goal_type, "min_value" => 0.5 }
      end
    end
  end

  private_class_method def self.account_thresholds(account)
    account.quality_thresholds.account_defaults.where(metric_type: METRIC_TYPES)
  end

  private_class_method def self.project_thresholds(project)
    project.quality_thresholds.where(metric_type: METRIC_TYPES)
  end

  private_class_method def self.apply_overrides(thresholds, overrides, source_scope)
    overrides.each do |threshold|
      threshold.source_scope = source_scope
      thresholds[key_for(threshold.metric_type, threshold.goal_type)] = threshold
    end
  end

  private_class_method def self.key_for(metric_type, goal_type)
    "#{goal_type}:#{metric_type}"
  end

  private_class_method def self.goal_matches?(threshold, goal_type)
    goal_type.blank? || threshold.goal_type == goal_type
  end

  private

  def assign_account_from_project
    self.account ||= project&.account
  end

  def project_belongs_to_account
    return if project.blank? || account.blank? || project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end

  def unique_scope
    return if account.blank? || metric_type.blank? || goal_type.blank?

    duplicate = self.class.where(account: account, project: project, metric_type: metric_type, goal_type: goal_type)
    duplicate = duplicate.where.not(id: id) if persisted?
    errors.add(:metric_type, "already has a threshold for this goal") if duplicate.exists?
  end
end
