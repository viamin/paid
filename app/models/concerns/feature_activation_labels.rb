# frozen_string_literal: true

module FeatureActivationLabels
  extend ActiveSupport::Concern

  DEFAULTS = {
    "paid_in_full" => "paid-in-full",
    "auto_pick" => "paid-automation",
    "auto_enhance" => "paid-enhance",
    "auto_merge" => "paid-auto-merge",
    "auto_scan_prs" => "paid-scan",
    "auto_scan_security" => "paid-scan-security",
    "auto_fix_merge_conflicts" => "paid-fix-conflicts",
    "auto_release" => "paid-auto-release",
    "tdd_strict" => "paid-tdd-strict",
    "tdd_auto" => "paid-tdd-auto"
  }.freeze
  KEYS = DEFAULTS.keys.freeze

  included do
    before_validation :normalize_feature_activation_labels
  end

  def feature_activation_labels_configured?
    !feature_activation_labels.nil?
  end

  def self.normalize(value)
    return nil if value.nil?

    value.to_h.each_with_object({}) do |(key, label), normalized|
      feature = key.to_s
      next unless KEYS.include?(feature)

      resolved = label.to_s.strip
      next if resolved.blank?

      normalized[feature] = resolved
    end
  end

  private

  # @spec AUTOMATION-ACTIVATION-001
  def normalize_feature_activation_labels
    self.feature_activation_labels = FeatureActivationLabels.normalize(feature_activation_labels)
  end
end
