# frozen_string_literal: true

Rails.application.config.after_initialize do
  Knowledge::CollectorRunner.register("symbol_index", Knowledge::Collectors::SymbolIndexCollector)
  Knowledge::CollectorRunner.register("dependency", Knowledge::Collectors::DependencyCollector)
  Knowledge::CollectorRunner.register("config_key", Knowledge::Collectors::ConfigKeyCollector)
end
