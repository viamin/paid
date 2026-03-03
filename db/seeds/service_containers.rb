# frozen_string_literal: true

# Seed default service containers for common infrastructure services.
# These are created with "stopped" status and can be associated with projects.

[
  {
    name: "postgres",
    image: "postgres:16",
    port: 5432,
    env: { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => SecureRandom.hex(16), "POSTGRES_DB" => "agent_db" }
  },
  {
    name: "redis",
    image: "redis:7-alpine",
    port: 6379,
    env: {}
  }
].each do |attrs|
  sc = ServiceContainer.find_or_initialize_by(name: attrs[:name])

  if sc.new_record?
    sc.image = attrs[:image]
    sc.port = attrs[:port]
    sc.env = attrs[:env]
    sc.status = "stopped"
  end

  # Skip validation: image_in_allowlist requires UserSetting records that
  # may not exist yet during initial db:seed.
  sc.save!(validate: false)

  Rails.logger.info(message: "seeds.service_container", name: attrs[:name], image: attrs[:image])
end
