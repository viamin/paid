# frozen_string_literal: true

module Prompts
  # Shared prompt sections for service container availability.
  # Included by both BuildForIssue and BuildForPr to provide
  # consistent database/infrastructure guardrails across all agent prompts.
  module ServiceContainerSections
    private

    def setup_database_instruction
      if has_database_container?
        if detected_language == "ruby"
          "   Run `bin/rails db:prepare` to set up the database (DATABASE_URL is already configured)."
        else
          "   A database service is already running and available via the `DATABASE_URL` environment variable." \
          " Use your framework's standard command to create and migrate the database schema."
        end
      else
        "   Do NOT run `bin/setup`, `db:prepare`, or `db:migrate` — no database is available in this environment."
      end
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
      containers = running_service_containers
      return "" if containers.empty?

      lines = containers.map { |sc| service_description(sc) }

      <<~SECTION

        # Available Services

        The following services are already running and available:
        #{lines.join("\n")}

        Do NOT install or build these services from source. They are already running.
        Use the environment variables above to connect.
      SECTION
    end

    def running_service_containers
      @running_service_containers ||= project.service_containers.running.to_a
    end

    def has_database_container?
      project.has_running_database_container?
    end

    def service_description(sc)
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
  end
end
