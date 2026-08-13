# frozen_string_literal: true

require "faraday"

module Github
  class InstallationRepositories
    API_BASE_URL = "https://api.github.com"
    PER_PAGE = 100

    class Error < StandardError; end
    class ConfigurationError < Error; end

    def self.fetch(installation_id:)
      new(installation_id: installation_id).fetch
    end

    def initialize(installation_id:)
      @installation_id = installation_id
    end

    def fetch
      raise ConfigurationError, "Paid Agents GitHub App is not configured" unless AppRegistry.configured?

      repositories = []
      page = 1

      loop do
        body = get_repositories_page(page)
        page_repositories = Array(body["repositories"])
        repositories.concat(page_repositories)

        total_count = body["total_count"].to_i
        break if page_repositories.size < PER_PAGE || repositories.size >= total_count

        page += 1
      end

      repositories.map { |repo| serialize_repository(repo) }
    end

    private

    attr_reader :installation_id

    def get_repositories_page(page)
      response = connection.get("/installation/repositories", per_page: PER_PAGE, page: page) do |request|
        request.headers["Accept"] = "application/vnd.github+json"
        request.headers["Authorization"] = "Bearer #{installation_token}"
      end

      parse_response(response)
    rescue Faraday::Error => e
      raise Error, "GitHub App installation repositories request failed: #{e.message}"
    end

    def installation_token
      @installation_token ||= begin
        jwt = AppJwt.sign(app_id: AppRegistry.app_id, private_key: AppRegistry.private_key)
        response = connection.post("/app/installations/#{installation_id}/access_tokens") do |request|
          request.headers["Accept"] = "application/vnd.github+json"
          request.headers["Authorization"] = "Bearer #{jwt}"
          request.headers["Content-Type"] = "application/json"
        end

        parse_response(response).fetch("token")
      end
    rescue KeyError => e
      raise Error, "GitHub App installation token response missing #{e.key}"
    rescue Faraday::Error => e
      raise Error, "GitHub App installation token request failed: #{e.message}"
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
      raise Error, "GitHub App installation repositories request failed (status #{response.status}): #{message}"
    rescue JSON::ParserError
      raise Error, "GitHub App installation repositories returned invalid JSON (status #{response.status})"
    end

    def serialize_repository(repo)
      {
        "id" => repo["id"],
        "full_name" => repo["full_name"],
        "name" => repo["name"],
        "owner" => repo.dig("owner", "login") || repo["full_name"].to_s.split("/").first,
        "default_branch" => repo["default_branch"],
        "private" => repo["private"] || false
      }
    end
  end
end
