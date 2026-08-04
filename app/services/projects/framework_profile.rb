# frozen_string_literal: true

module Projects
  class FrameworkProfile
    LABELS = {
      "rails" => "Rails",
      "phoenix" => "Phoenix",
      "nextjs" => "Next.js",
      "django" => "Django",
      "generic" => "Unknown"
    }.freeze

    NORMALIZED_KEYS = {
      "rails" => "rails",
      "phoenix" => "phoenix",
      "nextjs" => "nextjs",
      "next.js" => "nextjs",
      "django" => "django",
      "generic" => "generic",
      "unknown" => "generic"
    }.freeze

    def self.normalize(value)
      return if value.blank?

      normalized = value.to_s.strip.downcase
      NORMALIZED_KEYS[normalized] || normalized.presence
    end

    def self.label_for(value)
      normalized = normalize(value)
      return if normalized.blank?

      LABELS[normalized] || value.to_s.strip.presence || normalized.humanize
    end
  end
end
