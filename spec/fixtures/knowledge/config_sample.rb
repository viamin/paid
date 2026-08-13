# frozen_string_literal: true

class ConfigSample
  def database_url
    ENV["DATABASE_URL"]
  end

  def redis_url
    ENV.fetch("REDIS_URL")
  end

  def api_key
    ENV['API_KEY']
  end

  def optional_key
    ENV.fetch('OPTIONAL_KEY')
  end
end
