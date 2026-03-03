# frozen_string_literal: true

# Seed default service containers for common infrastructure services.
# These are created with "stopped" status and can be associated with projects.

[
  {
    name: "postgres",
    image: "postgres:16",
    port: 5432,
    env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_db" }
  },
  {
    name: "redis",
    image: "redis:7-alpine",
    port: 6379,
    env: {}
  }
].each do |attrs|
  ServiceContainer.find_or_create_by!(name: attrs[:name]) do |sc|
    sc.image = attrs[:image]
    sc.port = attrs[:port]
    sc.env = attrs[:env]
    sc.status = "stopped"
  end

  Rails.logger.info(message: "seeds.service_container", name: attrs[:name], image: attrs[:image])
end
