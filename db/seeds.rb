# frozen_string_literal: true

# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

TenantContext.with_system_access do
  # Sample account and user for development/testing
  unless User.exists?(email: "test@example.com")
    account = Account.find_or_create_by!(name: "Test Team", slug: "test-team")

    User.create!(
      account: account,
      name: "Test User",
      email: "test@example.com",
      password: "password",
      password_confirmation: "password"
    )

    Rails.logger.info(message: "seeds.created_test_user", email: "test@example.com")
  end

  # Seed default service containers
  load Rails.root.join("db/seeds/service_containers.rb")

  # Seed default prompts
  load Rails.root.join("db/seeds/prompts.rb")

  # Seed default global style guides
  load Rails.root.join("db/seeds/style_guides.rb")

  # Seed default orchestration strategies
  OrchestrationStrategies::Seed.call

  # Seed baseline learned-orchestration strategies (formerly seeded by the
  # 20260509233216 migration; see that file for why it moved here)
  Strategies::SeedBaselineOrchestration.call
end
