class AddComplexityThresholdsToProviders < ActiveRecord::Migration[8.1]
  # Maps a complexity score (1-10) to a model tier. A task with complexity
  # <= low_max routes to the "low" tier, <= mid_max routes to "mid", and
  # anything higher routes to "high". Stored as JSONB per-provider so
  # thresholds are data-driven rather than hardcoded in Ruby, and so each
  # provider can tune its own complexity->tier mapping.
  DEFAULT_COMPLEXITY_THRESHOLDS = { "low_max" => 3, "mid_max" => 7 }.freeze

  def change
    add_column :providers, :complexity_thresholds, :jsonb,
      default: DEFAULT_COMPLEXITY_THRESHOLDS, null: false
  end
end
