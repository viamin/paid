# frozen_string_literal: true

module Prompts
  # Shared prompt sections for service container availability.
  # Included by both BuildForIssue and BuildForPr to provide
  # consistent database/infrastructure guardrails across all agent prompts.
  module ServiceContainerSections
    RUBY_DB_SETUP_SLUG = "service_environment.setup.ruby_db"
    FRAMEWORK_DB_SETUP_SLUG = "service_environment.setup.framework_db"
    NO_DB_SETUP_SLUG = "service_environment.setup.no_db"
    AVAILABLE_SERVICES_INTRO_SLUG = "service_environment.available_services_intro"
    ENVIRONMENT_CONSTRAINTS_NO_DB_SLUG = "service_environment.environment_constraints_no_db"

    # Public module method: returns the indented database setup instruction
    # line that goes between the install-deps step and the analyze step in
    # the issue prompt. Used by both BuildForIssue and CreateAgentRunActivity
    # so the prompt template can carry a {{setup_database_instruction}} slot.
    def self.setup_database_instruction_for(project:)
      containers = project.service_containers.to_a
      has_db = containers.any? { |sc| sc.image.include?("postgres") }
      language = Prompts::LanguageCommands.detected_language(project)
      render_database_instruction(has_db: has_db, language: language, project: project)
    end

    def self.build_database_instruction(has_db:, language:)
      if has_db
        if language == "ruby"
          "   Run `bin/rails db:prepare` to set up the database (`DATABASE_URL` will be configured for you)."
        else
          "   A database service will be available via the `DATABASE_URL` environment variable." \
          " Use your framework's standard command to create and migrate the database schema."
        end
      else
        "   Do NOT run `bin/setup`, `db:prepare`, or `db:migrate` — no database is available in this environment."
      end
    end

    def self.available_services_intro
      "The following services are configured for this project and will be available in the agent environment:"
    end

    def self.environment_constraints_no_db
      <<~SECTION
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

    def self.service_environment_section_for(project:, include_setup_instruction: true)
      containers = project.service_containers.to_a
      has_db = containers.any? { |sc| sc.image.include?("postgres") }

      sections = []

      if include_setup_instruction
        language = Prompts::LanguageCommands.detected_language(project)
        sections << <<~SECTION
          # Service Environment

          #{render_database_instruction(has_db: has_db, language: language, project: project)}
        SECTION
      end

      if containers.any?
        lines = containers.map { |sc| service_description(sc) }
        sections << <<~SECTION

          # Available Services

          #{render_available_services_intro(project: project)}
          #{lines.join("\n")}

          Do NOT install or build these services from source.
          Use the provided environment variables to connect.
        SECTION
      end

      unless has_db
        sections << <<~SECTION

          # Environment Constraints

          #{render_environment_constraints_no_db(project: project)}
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
      ServiceContainerSections.render_database_instruction(
        has_db: has_database_container?,
        language: detected_language,
        project: project
      )
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

        #{ServiceContainerSections.render_environment_constraints_no_db(project: project)}
      SECTION
    end

    def available_services_section
      containers = configured_service_containers
      return "" if containers.empty?

      lines = containers.map { |sc| service_description(sc) }

      <<~SECTION

        # Available Services

        #{ServiceContainerSections.render_available_services_intro(project: project)}
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

    class << self
      def render_database_instruction(has_db:, language:, project:)
        slug = if has_db
          language == "ruby" ? RUBY_DB_SETUP_SLUG : FRAMEWORK_DB_SETUP_SLUG
        else
          NO_DB_SETUP_SLUG
        end

        render_prompt_block(
          slug: slug,
          project: project,
          fallback: -> { build_database_instruction(has_db: has_db, language: language) }
        )
      end

      def render_available_services_intro(project:)
        render_prompt_block(
          slug: AVAILABLE_SERVICES_INTRO_SLUG,
          project: project,
          fallback: -> { available_services_intro }
        )
      end

      def render_environment_constraints_no_db(project:)
        render_prompt_block(
          slug: ENVIRONMENT_CONSTRAINTS_NO_DB_SLUG,
          project: project,
          fallback: -> { environment_constraints_no_db }
        )
      end

      private

      def render_prompt_block(slug:, project:, fallback:)
        Prompts::Render.call(
          slug: slug,
          project: project,
          variables: {},
          fallback: fallback
        )
      end
    end
  end
end
