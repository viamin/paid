# frozen_string_literal: true

module AutoPickSkipLabels
  extend ActiveSupport::Concern

  DEFAULTS = %w[planning research waiting tracking epic needs-manual-setup].freeze

  included do
    before_validation :normalize_auto_pick_skip_labels
  end

  def auto_pick_skip_labels_configured?
    !auto_pick_skip_labels.nil?
  end

  def auto_pick_skip_labels_csv
    AutoPickSkipLabels.to_csv(auto_pick_skip_labels)
  end

  def auto_pick_skip_labels_csv=(value)
    self.auto_pick_skip_labels = AutoPickSkipLabels.parse_csv(value)
  end

  def self.normalize(value)
    return nil if value.nil?

    Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def self.parse_csv(value)
    normalize(value.to_s.split(",")) || []
  end

  def self.to_csv(value)
    Array(value).join(", ")
  end

  private

  def normalize_auto_pick_skip_labels
    self.auto_pick_skip_labels = AutoPickSkipLabels.normalize(auto_pick_skip_labels)
  end
end
