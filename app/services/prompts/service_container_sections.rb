# frozen_string_literal: true

module Prompts
  # Shared prompt sections for service container availability.
  # Included by both BuildForIssue and BuildForPr to provide
  # consistent database/infrastructure guardrails across all agent prompts.
  module ServiceContainerSections
    # Public module method: generates the service-environment text for a
    # project without requiring a full BuildForIssue/BuildForPr instance.
    # Used by CreateAgentRunActivity to append service guidance to rendered
    # PromptVersion custom_prompts.
    def self.service_environment_section_for(project:)
      containers = project.service_containers.to_a
      has_db = containers.any? { |sc| sc.image.include?("postgres") }
      language = Prompts::LanguageCommands.detected_language(project)

      sections = []

      # Setup instruction
      setup = if has_db
        if language == "ruby"
          "   Run `bin/rails db:prepare` to set up the database (`DATABASE_URL` will be configured for you)."
        else
          "   A database service will be available via the `DATABASE_URL` environment variable." \
          " Use your framework's standard command to create and migrate the database schema."
        end
      else
        "   Do NOT run `bin/setup`, `db:prepare`, or `db:migrate` — no database is available in this environment."
      end

      sections << <<~SECTION
        # Service Environment

        #{setup}
      SECTION

      if containers.any?
        lines = containers.map { |sc| service_description(sc) }
        sections << <<~SECTION

          # Available Services

          The following services are configured for this project and will be available in the agent environment:
          #{lines.join("\n")}

          Do NOT install or build these services from source.
          Use the provided environment variables to connect.
        SECTION
      end

      unless has_db
        sections << <<~SECTION

          # Environment Constraints

          You are running in an isolated container WITHOUT database services.
          Do NOT attempt to install PostgreSQL, Redis, or any other infrastructure service.
          Do NOT run `bin/setup`, `bin/rails db:prepare`, `bin/rails db:migrate`, or `initdb`.

          If a task requires database access and none is available:
          - Implement the code changes and write tests that use mocks, factories, or other
            techniques that do not require a real database connection.
          - Do NOT attempt to start or provision your own database server.
          - If the default test command or pre-commit hook fails because it cannot reach the
            database, run whatever subset of tests can pass without a database and clearly
            explain in your final answer which tests could not be run due to missing services.
        SECTION
      end

      sections.join
    end

    # Reuse service_description logic for the module-level method.
    def self.service_description(sc)
      if sc.image.include?("postgres")
        "- PostgreSQL is available via the `DATABASE_URL` environment variable."
      elsif sc.image.include?("redis")
        "- Redis is available via the `REDIS_URL` environment variable."
      elsif sc.image.include?("selenium") || sc.image.include?("chromium")
        "- Selenium/Chromium is available via the `SELENIUM_URL` environment variable."
      else
        "- #{sc.name} is available at host `#{sc.name}` on port #{sc.port}."
      end
    end

    private

    def setup_database_instruction
      if has_database_container?
        if detected_language == "ruby"
          "   Run `bin/rails db:prepare` to set up the database (`DATABASE_URL` will be configured for you)."
        else
          "   A database service will be available via the `DATABASE_URL` environment variable." \
          " Use your framework's standard command to create and migrate the database schema."
        end
      else
        "   Do NOT run `bin/setup`, `db:prepare`, or `db:migrate` — no database is available in this environment."
      end
    end

    def service_environment_section(include_setup_instruction: false)
      sections = []

      if include_setup_instruction
        sections << <<~SECTION
          # Service Environment

          #{setup_database_instruction}
        SECTION
      end

      services = available_services_section
      sections << services if services.present?

      constraints = no_infrastructure_section
      sections << constraints if constraints.present?

      sections.join
    end

    def no_infrastructure_section
      return "" if has_database_container?

      <<~SECTION

        # Environment Constraints

        You are running in an isolated container WITHOUT database services.
        Do NOT attempt to install PostgreSQL, Redis, or any other infrastructure service.
        Do NOT run `bin/setup`, `bin/rails db:prepare`, `bin/rails db:migrate`, or `initdb`.

        If a task requires database access and none is available:
        - Implement the code changes and write tests that use mocks, factories, or other
          techniques that do not require a real database connection.
        - Do NOT attempt to start or provision your own database server.
        - If the default test command or pre-commit hook fails because it cannot reach the
          database, run whatever subset of tests can pass without a database and clearly
          explain in your final answer which tests could not be run due to missing services.
      SECTION
    end

    def available_services_section
      containers = configured_service_containers
      return "" if containers.empty?

      lines = containers.map { |sc| service_description(sc) }

      <<~SECTION

        # Available Services

        The following services are configured for this project and will be available in the agent environment:
        #{lines.join("\n")}

        Do NOT install or build these services from source.
        Use the provided environment variables to connect.
      SECTION
    end

    def configured_service_containers
      @configured_service_containers ||= project.service_containers.to_a
    end

    def has_database_container?
      return @has_database_container unless @has_database_container.nil?

      @has_database_container = configured_service_containers.any? do |sc|
        sc.image.include?("postgres")
      end
    end

    def service_description(sc)
      ServiceContainerSections.service_description(sc)
    end
  end
end
