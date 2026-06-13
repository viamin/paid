# frozen_string_literal: true

Rails.application.config.to_prepare do
  Knowledge::CollectorRunner.reset_registry!
  Knowledge::CollectorRunner.register("churn_hotspot", Knowledge::Collectors::ChurnHotspotCollector)
  Knowledge::CollectorRunner.register("language_stat", Knowledge::Collectors::LanguageStatsCollector)
  Knowledge::CollectorRunner.register("symbol_index", Knowledge::Collectors::SymbolIndexCollector)
  Knowledge::CollectorRunner.register("dependency", Knowledge::Collectors::DependencyCollector)
  Knowledge::CollectorRunner.register("config_key", Knowledge::Collectors::ConfigKeyCollector)
  Knowledge::CollectorRunner.register("project_conventions", Knowledge::Collectors::ProjectConventionsCollector)
  Knowledge::CollectorRunner.register("routes", Knowledge::Collectors::RoutesCollector)
  Knowledge::CollectorRunner.register("tree_sitter", Knowledge::Collectors::TreeSitterCollector)
  Knowledge::CollectorRunner.register("decision_record", Knowledge::Collectors::DecisionRecordCollector)
  Knowledge::CollectorRunner.register("schema", Knowledge::Collectors::SchemaCollector)
end
