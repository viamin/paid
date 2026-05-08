# frozen_string_literal: true

FactoryBot.define do
  factory :configuration_bundle do
    sequence(:fingerprint) { |n| Digest::SHA256.hexdigest("configuration-bundle-#{n}") }
    definition { { "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code" } }
  end
end
