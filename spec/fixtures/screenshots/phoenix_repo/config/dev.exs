import Config

config :color_matching, ColorMatching.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "color_matching_dev",
  show_sensitive_data_on_connection_error: true

config :color_matching, ColorMatchingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  code_reloader: true,
  check_origin: false,
  secret_key_base: "secret",
  watchers: []

config :color_matching, :redis,
  url: System.get_env("REDIS_URL", "redis://localhost:6379/0")
