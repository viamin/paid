import Config

config :color_matching, ColorMatching.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "color_matching_dev",
  adapter: Ecto.Adapters.Postgres

config :color_matching, ColorMatching.Redis,
  url: "redis://localhost:6379/0",
  pool_size: 5
