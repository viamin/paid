# frozen_string_literal: true

module AutoPickSkipLabels
  DEFAULTS = %w[planning research waiting tracking epic needs-manual-setup].freeze

  module_function

  def normalize(value)
    return nil if value.nil?

    Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def parse_csv(value)
    normalize(value.to_s.split(",")) || []
  end

  def to_csv(value)
    Array(value).join(", ")
  end
end
