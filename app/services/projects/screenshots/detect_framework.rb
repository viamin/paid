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
        detection = ::Screenshots::DetectFramework.call(project: project)
        package_json = parse_package_json(fetch_file("package.json"))
        framework = present_framework_name(detection.framework)
        confidence = confidence_label(detection.confidence)
        driver = detection.suggested_config["driver"]
        setup_commands = suggest_setup_commands(framework:, package_json:)

        Result.new(
          framework: framework,
          confidence: confidence,
          driver: driver,
          service_dependencies: detection.detected_services,
          setup_commands: setup_commands,
          suggested_config: detection.suggested_config,
          suggested_yaml: detection.suggested_yaml,
          detected_at: Time.current.iso8601
        )
      end

      private

      def fetch_file(path)
        project.client.file_content(project.full_name, path: path)
      rescue GithubClient::NotFoundError
        nil
      end

      def parse_package_json(content)
        return {} if content.blank?

        JSON.parse(content)
      rescue JSON::ParserError
        {}
      end

      def suggest_setup_commands(framework:, package_json:)
        commands = case framework
        when "Rails"
          [ "bin/setup --skip-server", "bin/rails db:prepare" ]
        when "Next.js"
          [ "yarn install" ]
        when "Phoenix"
          [ "mix deps.get" ]
        else
          []
        end

        commands << "yarn build" if package_dependencies(package_json).include?("vite")
        commands.uniq
      end

      def present_framework_name(framework)
        {
          rails: "Rails",
          nextjs: "Next.js",
          phoenix: "Phoenix",
          django: "Django",
          generic: "Unknown"
        }.fetch(framework) { framework.to_s.humanize.presence || "Unknown" }
      end

      def confidence_label(confidence)
        score = confidence.to_f
        return "high" if score >= 0.85
        return "medium" if score >= 0.5

        "low"
      end

      def package_dependencies(package_json)
        %w[dependencies devDependencies].flat_map do |key|
          package_json.fetch(key, {}).keys
        end
      end
    end
  end
end
