# frozen_string_literal: true

module Github
  # Migrates projects from GitHub Personal Access Token (PAT) authentication
  # to GitHub App installation authentication. Supports both individual project
  # migration and bulk account-level migration with progress tracking.
  #
  # @example Migrate a single project
  #   Github::MigrationService.migrate_project(
  #     project: project,
  #     github_installation: installation,
  #     actor: current_user
  #   )
  #
  # @example Bulk migrate all projects from a token
  #   Github::MigrationService.migrate_from_token(
  #     github_token: token,
  #     github_installation: installation,
  #     actor: current_user
  #   )
  class MigrationService
    class MigrationError < StandardError; end
    class UnsupportedRepositoryError < MigrationError; end
    class InstallationAccessDeniedError < MigrationError; end

    attr_reader :project, :github_token, :github_installation, :actor, :options

    # Migrate a single project from PAT to GitHub App
    #
    # @param project [Project] The project to migrate
    # @param github_installation [GithubInstallation] Target GitHub App installation
    # @param actor [User] User performing the migration (for audit trail)
    # @param options [Hash] Additional migration options
    # @return [Result] Migration result with status and any warnings
    def self.migrate_project(project:, github_installation:, actor:, **options)
      new(
        project: project,
        github_installation: github_installation,
        actor: actor,
        **options
      ).migrate
    end

    # Migrate all projects from a GitHub token to a GitHub App installation
    #
    # @param github_token [GithubToken] Source PAT
    # @param github_installation [GithubInstallation] Target GitHub App installation
    # @param actor [User] User performing the migration
    # @param options [Hash] Additional migration options (filter_repos: [])
    # @return [BulkResult] Summary of migration with per-project results
    def self.migrate_from_token(github_token:, github_installation:, actor:, **options)
      new(
        github_token: github_token,
        github_installation: github_installation,
        actor: actor,
        **options
      ).migrate_all
    end

    # Check which repositories from a token are accessible via an installation
    #
    # @param github_token [GithubToken] Source PAT
    # @param github_installation [GithubInstallation] Target installation
    # @return [Hash{String => Symbol}] Map of repo full_name to access status
    def self.check_accessibility(github_token:, github_installation:)
      new(
        github_token: github_token,
        github_installation: github_installation,
        actor: nil
      ).check_all_repositories
    end

    def initialize(project: nil, github_token: nil, github_installation:, actor: nil, **options)
      @project = project
      @github_token = github_token || project&.github_token
      @github_installation = github_installation
      @actor = actor
      @options = options
    end

    # Perform single project migration
    # @return [Result]
    def migrate
      validate_preconditions!
      verify_installation_access!

      perform_migration
      log_migration_event("project.migrated", project: project)

      Result.new(
        success: true,
        project: project,
        previous_token_id: previous_token_id
      ).tap do |result|
        result.warnings = build_warnings
      end
    rescue MigrationError => e
      Result.new(success: false, project: project, error: e.message)
    end

    # Migrate all projects from the source token
    # @return [BulkResult]
    def migrate_all
      raise MigrationError, "github_token is required for bulk migration" unless github_token

      projects_to_migrate = github_token.projects.to_a
      return BulkResult.new(total: 0, successful: 0, failed: 0, results: []) if projects_to_migrate.empty?

      accessible_repo_ids = accessible_installation_repos.pluck("id")
      results = projects_to_migrate.map do |project|
        begin
          service = self.class.new(
            project: project,
            github_token: github_token,
            github_installation: github_installation,
            actor: actor,
            **options
          )
          result = service.migrate

          unless accessible_repo_ids.include?(project.github_id)
            result.warnings ||= []
            result.warnings << "Repository not in installation's accessible repos - manual admin may be required"
          end

          result
        rescue MigrationError => e
          Result.new(success: false, project: project, error: e.message)
        end
      end

      BulkResult.new(
        total: results.size,
        successful: results.count(&:success?),
        failed: results.count { |r| !r.success? },
        results: results
      )
    end

    # Check which repos are accessible via the installation
    # @return [Hash{String => Symbol}]
    def check_all_repositories
      raise MigrationError, "github_token is required" unless github_token

      accessible_repo_ids = accessible_installation_repos.pluck("id").to_set
      repo_by_name = github_token.accessible_repositories.index_by { |repo| repo["full_name"] }

      repo_by_name.each_with_object({}) do |(full_name, repo), result|
        if accessible_repo_ids.include?(repo["id"])
          result[full_name] = :accessible
        else
          result[full_name] = :requires_admin_action
        end
      end
    end

    private

    attr_reader :previous_token_id

    def validate_preconditions!
      raise MigrationError, "github_installation is required" unless github_installation
      raise MigrationError, "GitHub App is not configured" unless AppRegistry.configured?

      if github_installation.account_id != (project&.account_id || github_token&.account_id)
        raise MigrationError, "Installation must belong to the same account as the project"
      end

      if github_token && github_token.account_id != github_installation.account_id
        raise MigrationError, "Token and installation must belong to the same account"
      end
    end

    def verify_installation_access!
      return unless github_token

      accessible_repo_ids = accessible_installation_repos.pluck("id").to_set
      target_repo_ids = if project
        [ project.github_id ]
      else
        github_token.projects.pluck(:github_id)
      end

      inaccessible = target_repo_ids.reject { |id| accessible_repo_ids.include?(id) }
      return if inaccessible.empty?

      # For single project migrations, this is a hard error
      raise InstallationAccessDeniedError,
        "Installation does not have access to repository. " \
        "Please request repository access in the GitHub App settings."
    end

    def accessible_installation_repos
      github_installation.accessible_repositories || []
    end

    def perform_migration
      @previous_token_id = project.github_token_id

      project.with_lock do
        project.update!(
          github_token: nil,
          github_installation: github_installation
        )
      end

      # Invalidate any cached GitHub data
      Github::CacheInvalidator.call(
        project: project,
        event: "migration",
        payload: { from: "pat", to: "github_app" }
      )

      # Record the migration in account activity
      record_migration_activity if actor
    end

    def build_warnings
      warnings = []

      if github_installation.repository_selection == "selected"
        repo = github_installation.accessible_repositories.find { |r| r["id"] == project.github_id }
        if repo
          warnings << "Repository '#{repo['full_name']}' was explicitly granted to the GitHub App"
        end
      end

      warnings
    end

    def log_migration_event(message, project:)
      Rails.logger.info(
        message: message,
        project_id: project.id,
        account_id: project.account_id,
        actor_id: actor&.id,
        previous_token_id: previous_token_id,
        new_installation_id: github_installation.id
      )
    end

    def record_migration_activity
      Accounts::RecordActivity.call(
        account: github_installation.account,
        actor: actor,
        action: "github_app.migration.completed",
        subject: project,
        metadata: {
          project_name: project.name,
          previous_token_id: previous_token_id,
          new_installation_id: github_installation.id,
          repository: project.full_name
        }
      )
    end

    # Value object representing a single migration result
    class Result
      attr_accessor :warnings
      attr_reader :project, :error, :previous_token_id

      def initialize(success:, project:, error: nil, previous_token_id: nil)
        @success = success
        @project = project
        @error = error
        @previous_token_id = previous_token_id
        @warnings = []
      end

      def success?
        @success
      end
    end

    # Value object representing bulk migration results
    class BulkResult
      attr_reader :results, :total, :successful, :failed

      def initialize(total:, successful:, failed:, results:)
        @total = total
        @successful = successful
        @failed = failed
        @results = results
      end

      def each_successful
        return enum_for(:each_successful) unless block_given?

        results.select(&:success?).each { |r| yield(r) }
      end

      def each_failed
        return enum_for(:each_failed) unless block_given?

        results.reject(&:success?).each { |r| yield(r) }
      end
    end
  end
end
