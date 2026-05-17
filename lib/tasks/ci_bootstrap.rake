# frozen_string_literal: true

namespace :ci do
  desc "Bootstrap the minimal default records required by schema-only CI test databases"
  task bootstrap_test_defaults: :environment do
    TenantContext.with_system_access do
      OrchestrationStrategies::Seed.call
      Strategies::SeedBaselineOrchestration.call
    end
  end
end
