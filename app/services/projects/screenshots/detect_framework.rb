# frozen_string_literal: true

require "json"

module Projects
  module Screenshots
    class DetectFramework
      Result = Struct.new(
        :framework,
        :confidence,
        :driver,
        :service_dependencies,
        :setup_commands,
        :suggested_config,
        :suggested_yaml,
        :detected_at,
        keyword_init: true
      )

      attr_reader :project

      def initialize(project:)
        @project = project
      end

      def self.call(...)
        new(...).call
      end

      def call
        gemfile = fetch_file("Gemfile")
        package_json = parse_package_json(fetch_file("package.json"))
        services = detect_services
        framework, confidence = detect_framework(gemfile:, package_json:)
        driver = suggest_driver(framework:, gemfile:, package_json:)
        setup_commands = suggest_setup_commands(framework:, package_json:)

        suggested_config = compact_hash(
          "framework" => framework,
          "driver" => driver,
          "auto_capture" => true,
          "services" => services,
          "setup" => setup_commands
        )

        Result.new(
          framework: framework,
          confidence: confidence,
          driver: driver,
          service_dependencies: services,
          setup_commands: setup_commands,
          suggested_config: suggested_config,
          suggested_yaml: YAML.dump(suggested_config),
          detected_at: Time.current.iso8601
        )
      end

      private

      def detect_services
        result = Projects::DetectServices.call(project: project)
        result.detected.map { |detection| detection[:service].to_s }.uniq.sort
      end

      def fetch_file(path)
        project.github_token.client.file_content(project.full_name, path: path)
      rescue GithubClient::NotFoundError
        nil
      end

      def parse_package_json(content)
        return {} if content.blank?

        JSON.parse(content)
      rescue JSON::ParserError
        {}
      end

      def detect_framework(gemfile:, package_json:)
        dependencies = package_dependencies(package_json)

        return [ "Rails", "high" ] if gemfile.to_s.match?(/^\s*gem\s+["']rails["']/)
        return [ "Next.js", "high" ] if dependencies.include?("next")
        return [ "React + Vite", "medium" ] if dependencies.include?("react") && dependencies.include?("vite")
        return [ "React", "medium" ] if dependencies.include?("react")

        [ "Unknown", "low" ]
      end

      def suggest_driver(framework:, gemfile:, package_json:)
        dependencies = package_dependencies(package_json)
        return "playwright" if dependencies.include?("@playwright/test")
        return "cuprite" if framework == "Rails" && gemfile.to_s.include?("cuprite")
        return "cuprite" if framework == "Rails"

        "playwright"
      end

      def suggest_setup_commands(framework:, package_json:)
        commands = case framework
        when "Rails"
          [ "bin/setup --skip-server", "bin/rails db:prepare" ]
        when "Next.js", "React", "React + Vite"
          [ "yarn install" ]
        else
          []
        end

        commands << "yarn build" if package_dependencies(package_json).include?("vite")
        commands.uniq
      end

      def package_dependencies(package_json)
        %w[dependencies devDependencies].flat_map do |key|
          package_json.fetch(key, {}).keys
        end
      end

      def compact_hash(hash)
        hash.compact.transform_values do |value|
          value.is_a?(Array) ? value.reject(&:blank?) : value
        end
      end
    end
  end
end
