# frozen_string_literal: true

require "faraday"

module Github
  class AppInstallation
    TOKEN_TTL = 50.minutes
    API_BASE_URL = "https://api.github.com"

    class Error < StandardError; end
    class ConfigurationError < Error; end

    def self.token_for(installation_id:, repo_full_name:)
      cache_key = cache_key(installation_id, repo_full_name)

      Rails.cache.fetch(cache_key, expires_in: TOKEN_TTL) do
        new(installation_id: installation_id, repo_full_name: repo_full_name).mint
      end
    end

    def self.cache_key(installation_id, repo_full_name)
      "github_app_installation_token:#{installation_id}:#{repo_full_name}"
    end

    # Clears the cached installation token so the next +token_for+ call
    # mints a fresh one. Called by +GithubClient+ when a 401 indicates the
    # cached token is no longer valid (e.g. installation re-suspended and
    # re-activated, or GitHub returned a token with a shorter lifetime).
    def self.clear_cached_token(installation_id:, repo_full_name:)
      Rails.cache.delete(cache_key(installation_id, repo_full_name))
    end

    def initialize(installation_id:, repo_full_name:)
      @installation_id = installation_id
      @repo_full_name = repo_full_name
    end

    def mint
      raise ConfigurationError, "Paid Agents GitHub App is not configured" unless AppRegistry.configured?

      jwt = AppJwt.sign(app_id: AppRegistry.app_id, private_key: AppRegistry.private_key)
      response = post("/app/installations/#{installation_id}/access_tokens", jwt)
      response.fetch("token")
    rescue KeyError => e
      raise Error, "GitHub App installation token response missing #{e.key}"
    end

    private

    attr_reader :installation_id, :repo_full_name

    def post(path, jwt)
      response = connection.post(path) do |request|
        request.headers["Accept"] = "application/vnd.github+json"
        request.headers["Authorization"] = "Bearer #{jwt}"
        request.headers["Content-Type"] = "application/json"
        request.body = { repositories: [ repo_full_name.split("/").last ] }.to_json
      end

      parse_response(response)
    end

    def connection
      @connection ||= Faraday.new(url: API_BASE_URL) do |faraday|
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
      end
    end

    def parse_response(response)
      body = JSON.parse(response.body)
      return body if response.success?

      message = body.is_a?(Hash) ? body["message"] : response.body
      raise Error, "GitHub App installation request failed (status #{response.status}): #{message}"
    rescue JSON::ParserError
      raise Error, "GitHub App installation returned invalid JSON (status #{response.status})"
    end
  end
end
