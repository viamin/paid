# frozen_string_literal: true

module Projects
  # Inspects repository files to detect required service dependencies.
  #
  # Parses Gemfile, package.json, docker-compose.yml, and config/database.yml
  # to identify services like PostgreSQL, Redis, Elasticsearch, etc.
  # Maps detected dependencies to existing ServiceContainer records.
  #
  # @example
  #   result = Projects::DetectServices.call(project: project)
  #   result.detected   # => [{ service: "postgres", source: "Gemfile", ... }]
  #   result.matched     # => [#<ServiceContainer name: "postgres">]
  #   result.unmatched   # => [{ service: "elasticsearch", source: "docker-compose.yml" }]
  class DetectServices
    # Maps dependency identifiers to canonical service names.
    # Keys are patterns found in Gemfile/package.json/docker-compose.
    # Values are canonical service names matching ServiceContainer.name.
    DEPENDENCY_MAP = {
      # PostgreSQL
      "pg" => "postgres",
      "postgres" => "postgres",
      "postgresql" => "postgres",
      # Redis
      "redis" => "redis",
      "redis-rb" => "redis",
      "ioredis" => "redis",
      "bull" => "redis",
      "sidekiq" => "redis",
      # MySQL
      "mysql2" => "mysql",
      "mysql" => "mysql",
      # MongoDB
      "mongoid" => "mongodb",
      "mongo" => "mongodb",
      "mongoose" => "mongodb",
      "mongodb" => "mongodb",
      # Elasticsearch
      "elasticsearch" => "elasticsearch",
      "elastic-apm" => "elasticsearch",
      "searchkick" => "elasticsearch",
      "@elastic/elasticsearch" => "elasticsearch",
      # Memcached
      "dalli" => "memcached",
      "memcached" => "memcached",
      "memjs" => "memcached",
      # Selenium
      "selenium" => "selenium",
      "selenium-webdriver" => "selenium"
    }.freeze

    # Gemfile gem patterns that indicate service dependencies.
    GEMFILE_PATTERNS = /^\s*gem\s+["']([^"']+)["']/.freeze

    # package.json dependency keys to inspect.
    PACKAGE_JSON_DEPENDENCY_KEYS = %w[dependencies devDependencies].freeze

    # docker-compose service image patterns mapped to canonical names.
    COMPOSE_IMAGE_PATTERNS = {
      /postgres/ => "postgres",
      /redis/ => "redis",
      /mysql|mariadb/ => "mysql",
      /mongo/ => "mongodb",
      /elasticsearch|opensearch/ => "elasticsearch",
      /memcache/ => "memcached",
      /selenium/ => "selenium"
    }.freeze

    # database.yml adapter patterns.
    DATABASE_ADAPTER_MAP = {
      "postgresql" => "postgres",
      "postgis" => "postgres",
      "mysql2" => "mysql",
      "trilogy" => "mysql",
      "mongo" => "mongodb"
    }.freeze

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      detections = []
      detections.concat(detect_from_gemfile)
      detections.concat(detect_from_package_json)
      detections.concat(detect_from_docker_compose)
      detections.concat(detect_from_database_yml)

      unique_services = detections.uniq { |d| d[:service] }
      containers = ServiceContainer.all.index_by(&:name)

      matched = []
      unmatched = []

      unique_services.each do |detection|
        container = containers[detection[:service]]
        if container
          matched << container
        else
          unmatched << detection
        end
      end

      Result.new(
        detected: unique_services,
        matched: matched.uniq,
        unmatched: unmatched
      )
    end

    private

    def fetch_file(path)
      client = project.github_token.client
      response = client.client.contents("#{project.owner}/#{project.repo}", path: path)
      decode_content(response)
    rescue GithubClient::NotFoundError, Octokit::NotFound
      nil
    rescue GithubClient::Error
      nil
    end

    def decode_content(response)
      return nil unless response&.content

      Base64.decode64(response.content).force_encoding("UTF-8")
    end

    def detect_from_gemfile
      content = fetch_file("Gemfile")
      return [] unless content

      detections = []
      content.each_line do |line|
        match = line.match(GEMFILE_PATTERNS)
        next unless match

        gem_name = match[1]
        service = DEPENDENCY_MAP[gem_name]
        next unless service

        detections << { service: service, source: "Gemfile", dependency: gem_name }
      end
      detections
    end

    def detect_from_package_json
      content = fetch_file("package.json")
      return [] unless content

      data = JSON.parse(content)
      detections = []

      PACKAGE_JSON_DEPENDENCY_KEYS.each do |key|
        deps = data[key]
        next unless deps.is_a?(Hash)

        deps.each_key do |dep_name|
          service = DEPENDENCY_MAP[dep_name]
          next unless service

          detections << { service: service, source: "package.json", dependency: dep_name }
        end
      end
      detections
    rescue JSON::ParserError
      []
    end

    def detect_from_docker_compose
      content = fetch_file("docker-compose.yml") || fetch_file("compose.yml")
      return [] unless content

      data = YAML.safe_load(content, permitted_classes: [ Symbol ])
      return [] unless data.is_a?(Hash)

      services = data["services"]
      return [] unless services.is_a?(Hash)

      detections = []
      services.each do |service_name, config|
        next unless config.is_a?(Hash)

        image = config["image"].to_s
        matched_service = match_compose_image(image) || match_compose_service_name(service_name)
        next unless matched_service

        detections << { service: matched_service, source: "docker-compose.yml", dependency: image.presence || service_name }
      end
      detections
    rescue Psych::SyntaxError
      []
    end

    def detect_from_database_yml
      content = fetch_file("config/database.yml")
      return [] unless content

      # Parse YAML but handle ERB-style templates by stripping them
      sanitized = content.gsub(/<%.*?%>/, '""')
      data = YAML.safe_load(sanitized, permitted_classes: [ Symbol ], aliases: true)
      return [] unless data.is_a?(Hash)

      detections = []
      data.each_value do |config|
        next unless config.is_a?(Hash)

        adapter = config["adapter"]
        service = DATABASE_ADAPTER_MAP[adapter]
        next unless service

        detections << { service: service, source: "config/database.yml", dependency: adapter }
      end
      detections
    rescue Psych::SyntaxError
      []
    end

    def match_compose_image(image)
      return nil if image.blank?

      COMPOSE_IMAGE_PATTERNS.each do |pattern, service|
        return service if image.match?(pattern)
      end
      nil
    end

    def match_compose_service_name(name)
      COMPOSE_IMAGE_PATTERNS.each do |pattern, service|
        return service if name.match?(pattern)
      end
      nil
    end

    # Result object returned by DetectServices.
    class Result
      attr_reader :detected, :matched, :unmatched

      def initialize(detected:, matched:, unmatched:)
        @detected = detected
        @matched = matched
        @unmatched = unmatched
      end

      def any_detected?
        detected.any?
      end
    end
  end
end
