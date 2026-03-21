# frozen_string_literal: true

require "base64"
require "json"
require "yaml"

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

    # Maximum size for YAML content to limit parsing of untrusted files.
    YAML_MAX_SIZE = 64_000

    # Maximum number of YAML alias nodes allowed. Limits exponential
    # expansion from small "YAML bomb" payloads that use nested aliases
    # (e.g., &a [*b,*b] chains). Checked via Psych AST before converting
    # to Ruby objects.
    MAX_YAML_ALIASES = 100

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
      detected_names = unique_services.map { |d| d[:service] }
      containers = ServiceContainer.where(name: detected_names).index_by(&:name)

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
      response = client.contents("#{project.owner}/#{project.repo}", path: path)
      decode_content(response)
    rescue GithubClient::NotFoundError
      nil
    end

    def decode_content(response)
      return nil unless response&.content

      Base64.decode64(response.content).force_encoding("UTF-8").scrub
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
      source_file = "docker-compose.yml"
      content = fetch_file(source_file)
      unless content
        source_file = "compose.yml"
        content = fetch_file(source_file)
      end
      return [] unless content
      return [] if content.bytesize > YAML_MAX_SIZE

      data = safe_yaml_load(content)
      return [] unless data.is_a?(Hash)

      services = data["services"]
      return [] unless services.is_a?(Hash)

      detections = []
      services.each do |service_name, config|
        next unless config.is_a?(Hash)

        image = config["image"].to_s
        matched_service = match_compose_image(image) || match_compose_service_name(service_name)
        next unless matched_service

        detections << { service: matched_service, source: source_file, dependency: image.presence || service_name }
      end
      detections
    rescue Psych::Exception
      []
    end

    def detect_from_database_yml
      content = fetch_file("config/database.yml")
      return [] unless content
      return [] if content.bytesize > YAML_MAX_SIZE

      # Parse YAML but handle ERB-style templates by stripping them.
      # Aliases are enabled because database.yml conventionally uses YAML
      # anchors (e.g., &default / <<: *default) to share config across environments.
      sanitized = content.gsub(/<%.*?%>/m, '""')
      data = safe_yaml_load(sanitized)
      return [] unless data.is_a?(Hash)

      detections = []
      extract_adapters(data) do |adapter|
        service = DATABASE_ADAPTER_MAP[adapter]
        next unless service

        detections << { service: service, source: "config/database.yml", dependency: adapter }
      end
      detections
    rescue Psych::Exception
      []
    end

    # Recursively walks a YAML hash to find all "adapter" values.
    # Handles both single-db (adapter at top level of each env) and
    # multi-db (adapter nested under primary/secondary sub-keys) configs.
    def extract_adapters(hash, &block)
      return unless hash.is_a?(Hash)

      hash.each_value do |value|
        next unless value.is_a?(Hash)

        if value.key?("adapter")
          yield value["adapter"]
        else
          extract_adapters(value, &block)
        end
      end
    end

    # Parses YAML via Psych AST with an alias count limit to prevent
    # exponential expansion from YAML bomb payloads. Returns nil if the
    # alias count exceeds MAX_YAML_ALIASES.
    def safe_yaml_load(content)
      tree = Psych.parse(content)
      return nil unless tree

      alias_count = count_yaml_aliases(tree)
      return nil if alias_count > MAX_YAML_ALIASES

      tree.to_ruby
    end

    def count_yaml_aliases(node)
      count = node.is_a?(Psych::Nodes::Alias) ? 1 : 0
      if node.respond_to?(:children) && node.children
        node.children.each { |child| count += count_yaml_aliases(child) }
      end
      count
    end

    def match_compose_image(image)
      return nil if image.blank?

      COMPOSE_IMAGE_PATTERNS.each do |pattern, service|
        return service if image.match?(pattern)
      end
      nil
    end

    def match_compose_service_name(name)
      return nil if name.blank?

      name_str = name.to_s
      COMPOSE_IMAGE_PATTERNS.each do |pattern, service|
        return service if name_str.match?(pattern)
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

      # Associates matched service containers with the project.
      # Returns the names of newly added associations.
      def apply(project)
        added = []
        matched.each do |container|
          psc = project.project_service_containers.find_or_create_by!(service_container: container)
          added << container.name if psc.previously_new_record?
        rescue ActiveRecord::RecordNotUnique
          next
        end
        added
      end

      def notice_message(added)
        parts = []
        parts << "Added #{added.join(', ')}." if added.any?
        if unmatched.any?
          names = unmatched.map { |d| d[:service] }.join(", ")
          parts << "#{names} detected but no matching service container exists."
        end
        already_count = matched.size - added.size
        parts << "#{already_count} already associated." if already_count > 0
        parts.join(" ").presence || "All detected services are already associated."
      end
    end
  end
end
