# frozen_string_literal: true

Rails.application.config.to_prepare do
  Knowledge::CollectorRunner.register("symbol_index", Knowledge::Collectors::SymbolIndexCollector)
  Knowledge::CollectorRunner.register("dependency", Knowledge::Collectors::DependencyCollector)
  Knowledge::CollectorRunner.register("config_key", Knowledge::Collectors::ConfigKeyCollector)
  Knowledge::CollectorRunner.register("routes", Knowledge::Collectors::RoutesCollector)
  Knowledge::CollectorRunner.register("tree_sitter", Knowledge::Collectors::TreeSitterCollector)
end
