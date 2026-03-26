# frozen_string_literal: true

Rails.application.config.after_initialize do
  Knowledge::CollectorRunner.register("churn_hotspot", Knowledge::Collectors::ChurnHotspotCollector)
  Knowledge::CollectorRunner.register("language_stat", Knowledge::Collectors::LanguageStatsCollector)
end
