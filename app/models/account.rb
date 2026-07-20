# frozen_string_literal: true

class Account < ApplicationRecord
  has_logidze
  MAX_SLUG_GENERATION_ATTEMPTS = 10
  PLANS = %w[trial free professional enterprise].freeze
  TRIAL_DURATION = 14.days
  REMEDIATION_POLICY_MODES = %w[notify_only auto_apply disabled].freeze
  DEFAULT_REMEDIATION_POLICY_ENTRY = {
    "mode" => "notify_only",
    "minimum_confidence" => 0.8,
    "filing_threshold" => 1
  }.freeze

  enum :status, { active: 0, suspended: 1, deactivated: 2 }

  has_many :users, dependent: :destroy
  has_many :account_memberships, dependent: :destroy
  has_many :account_activity_events, dependent: :destroy
  has_many :members, through: :account_memberships, source: :user
  has_many :provider_api_keys, through: :users
  has_many :projects, dependent: :destroy
  has_many :roi_benchmarks, through: :projects
  has_many :github_tokens, dependent: :destroy
  has_many :github_installations, dependent: :destroy
  has_many :integration_credentials, dependent: :destroy
  has_many :claude_login_sessions, dependent: :destroy
  has_many :runner_credentials, dependent: :destroy
  has_many :linear_tokens, dependent: :destroy
  has_many :prompts, -> { where(project_id: nil) }, dependent: :destroy
  has_many :all_prompts, class_name: "Prompt"
  has_many :strategies, -> { where(project_id: nil) }, dependent: :destroy
  has_many :all_strategies, class_name: "Strategy"
  has_many :style_guides, -> { where(project_id: nil) }, dependent: :destroy
  has_many :style_guide_ab_tests, dependent: :destroy
  has_many :mcp_server_definitions, dependent: :destroy
  has_many :marketplace_entries, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :remediation_decisions, dependent: :destroy
  has_many :pre_commit_requirements, dependent: :destroy
  has_one :tracker_configuration, as: :configurable, dependent: :destroy
  has_one :tenant_setting, dependent: :destroy
  has_many :pr_templates, dependent: :destroy
  has_many :onboarding_steps, dependent: :destroy
  has_many :billing_invoices, dependent: :destroy
  has_many :billing_periods, dependent: :destroy
  has_many :billing_plans, dependent: :destroy
  has_many :service_containers, dependent: :destroy
  has_many :chat_sessions, dependent: :destroy
  has_many :quality_thresholds, dependent: :destroy
  has_many :exception_incidents, dependent: :destroy
  has_many :configuration_bundles, dependent: :destroy
  has_many :orchestration_strategies, dependent: :destroy
  has_many :strategy_experiments, dependent: :destroy
  has_many :coordination_policies, dependent: :destroy
  has_one :dispatch_circuit_breaker, dependent: :destroy

  validates :name, presence: true
  validates :plan, presence: true, inclusion: { in: PLANS }
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "can only contain lowercase letters, numbers, and hyphens" }
  validates :default_max_tokens_per_run,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 2_147_483_647 }
  validate :remediation_policy_must_be_valid

  before_validation :generate_slug, on: :create
  before_validation :normalize_remediation_policy!

  def save(**options)
    super
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?("slug")

    regenerate_slug_and_retry
  end

  def save!(**options)
    super
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?("slug")

    regenerate_slug_and_retry!
  end

  def scheduler_paused?
    scheduler_paused_at.present?
  end

  def suspend!
    raise InvalidTransitionError, "only active accounts can be suspended" unless active?

    update!(status: :suspended, suspended_at: Time.current)
  end

  def reactivate!
    raise InvalidTransitionError, "only suspended or deactivated accounts can be reactivated" if active?

    update!(status: :active, suspended_at: nil, deactivated_at: nil)
  end

  def deactivate!
    raise InvalidTransitionError, "only suspended accounts can be deactivated" unless suspended?

    update!(status: :deactivated, deactivated_at: Time.current)
  end

  def tenant_setting!
    tenant_setting || create_tenant_setting!
  rescue ActiveRecord::RecordNotUnique
    reload_tenant_setting
  end

  def tenant_max_concurrent_runs(limit)
    tenant_setting&.cap_max_concurrent_runs(limit) || limit
  end

  def tenant_max_concurrent_create_pr_runs
    tenant_setting&.max_concurrent_create_pr_runs || TenantSetting::DEFAULT_GUARDRAILS.fetch("max_concurrent_create_pr_runs")
  end

  def tenant_max_tokens_per_run(limit)
    tenant_setting&.cap_max_tokens_per_run(limit) || limit
  end

  def onboarding_completed?
    onboarding_completed_at.present?
  end

  def trial?
    plan == "trial"
  end

  def trial_expired?
    trial? && trial_ends_at.present? && trial_ends_at < Time.current
  end

  def paid_plan?
    plan.in?(%w[professional enterprise])
  end

  def current_onboarding_step
    onboarding_steps.ordered.where.not(status: %w[completed skipped]).first
  end

  def onboarding_progress
    total = onboarding_steps.count
    return 0 if total.zero?

    done = onboarding_steps.where(status: %w[completed skipped]).count
    (done.to_f / total * 100).round
  end

  class InvalidTransitionError < StandardError; end

  # Returns the fallback owner for this account — the first owner by ID,
  # or the first user by ID if no owner membership exists. Used for
  # orphaned-project ownership resolution.
  def fallback_owner
    account_memberships.where(role: :owner).order(:id).first&.user ||
      users.order(:id).first
  end

  # Returns just the fallback owner's ID without loading the User record.
  def fallback_owner_id
    account_memberships.where(role: :owner).order(:id).pick(:user_id) ||
      users.order(:id).pick(:id)
  end

  def self.batch_fallback_owner_ids(account_ids)
    account_ids = account_ids.compact.uniq
    return {} if account_ids.empty?

    owner_ids = AccountMembership.where(account_id: account_ids, role: :owner)
      .order(:account_id, :id)
      .pluck(:account_id, :user_id)
      .each_with_object({}) { |(aid, uid), memo| memo[aid] ||= uid }

    missing = account_ids - owner_ids.keys
    return owner_ids if missing.empty?

    User.where(account_id: missing)
      .order(:account_id, :id)
      .pluck(:account_id, :id)
      .each { |aid, uid| owner_ids[aid] ||= uid }

    owner_ids
  end

  def primary_owner_membership
    account_memberships.where(role: :owner).order(:id).first
  end

  def primary_owner
    primary_owner_membership&.user
  end

  def effective_remediation_policy
    actions = defined?(RemediationDecision) ? RemediationDecision::PROPOSED_ACTIONS : []

    actions.index_with do |action|
      DEFAULT_REMEDIATION_POLICY_ENTRY.merge(
        normalized_remediation_policy.fetch(action, {})
      )
    end
  end

  def remediation_policy_for(action)
    effective_remediation_policy.fetch(action.to_s, DEFAULT_REMEDIATION_POLICY_ENTRY)
  end

  private

  def normalized_remediation_policy
    (remediation_policy.is_a?(Hash) ? remediation_policy : {})
      .deep_stringify_keys
      .slice(*(defined?(RemediationDecision) ? RemediationDecision::PROPOSED_ACTIONS : []))
  end

  def normalize_remediation_policy!
    self.remediation_policy = normalized_remediation_policy.each_with_object({}) do |(action, settings), result|
      next unless settings.is_a?(Hash)

      normalized = settings.deep_stringify_keys.slice("mode", "minimum_confidence", "filing_threshold")
      normalized["mode"] = normalized["mode"].to_s if normalized.key?("mode")

      if normalized.key?("minimum_confidence")
        normalized["minimum_confidence"] = normalized["minimum_confidence"].to_f
      end

      if normalized.key?("filing_threshold")
        normalized["filing_threshold"] = normalized["filing_threshold"].to_i
      end

      result[action] = normalized
    end
  end

  def remediation_policy_must_be_valid
    return if remediation_policy.blank?
    return errors.add(:remediation_policy, "must be a hash keyed by remediation action") unless remediation_policy.is_a?(Hash)

    unknown_actions = remediation_policy.keys.map(&:to_s) - RemediationDecision::PROPOSED_ACTIONS
    if unknown_actions.any?
      errors.add(:remediation_policy, "contains unknown action(s): #{unknown_actions.join(', ')}")
    end

    normalized_remediation_policy.each do |action, settings|
      unless settings.is_a?(Hash)
        errors.add(:remediation_policy, "#{action} must be a hash of mode and thresholds")
        next
      end

      mode = settings["mode"]
      if mode.present? && !REMEDIATION_POLICY_MODES.include?(mode)
        errors.add(:remediation_policy, "#{action} mode must be one of: #{REMEDIATION_POLICY_MODES.join(', ')}")
      end

      if settings.key?("minimum_confidence")
        confidence = settings["minimum_confidence"]
        unless confidence.is_a?(Numeric) && confidence.between?(0.0, 1.0)
          errors.add(:remediation_policy, "#{action} minimum_confidence must be between 0.0 and 1.0")
        end
      end

      if settings.key?("filing_threshold")
        threshold = settings["filing_threshold"]
        unless threshold.is_a?(Integer) && threshold.positive?
          errors.add(:remediation_policy, "#{action} filing_threshold must be a positive integer")
        end
      end
    end
  end

  def generate_slug
    return if slug.present?
    return if name.blank?

    base_slug = name.parameterize
    self.slug = base_slug

    counter = 1
    while self.class.exists?(slug: slug)
      self.slug = "#{base_slug}-#{counter}"
      counter += 1
    end
  end

  def regenerate_slug_and_retry(attempt: 1)
    raise ActiveRecord::RecordNotUnique, "Could not generate unique slug" if attempt > MAX_SLUG_GENERATION_ATTEMPTS

    self.slug = "#{slug_base}-#{SecureRandom.hex(4)}"
    save || regenerate_slug_and_retry(attempt: attempt + 1)
  end

  def regenerate_slug_and_retry!(attempt: 1)
    raise ActiveRecord::RecordNotUnique, "Could not generate unique slug" if attempt > MAX_SLUG_GENERATION_ATTEMPTS

    self.slug = "#{slug_base}-#{SecureRandom.hex(4)}"
    save!
  rescue ActiveRecord::RecordNotUnique
    regenerate_slug_and_retry!(attempt: attempt + 1)
  end

  def slug_base
    slug&.sub(/-[a-f0-9]{8}$/, "")&.sub(/-\d+$/, "") || name&.parameterize
  end
end
