# frozen_string_literal: true

module Projects
  # Creates a brand-new project from scratch (issue #3954): provisions a
  # blank GitHub repository under an authorized owner using the selected
  # credential (PAT or paid-agents App installation), persists the matching
  # Paid project, and opens a GitHub bootstrap issue carrying the grill-me
  # setup questionnaire.
  #
  # Agent runs on the created project start from a blank slate: the initial
  # tooling choices (language/framework, dependencies, CI, conventions) are
  # captured afterwards through chat (default recommendation), the context
  # intake questionnaire, or the bootstrap issue itself.
  #
  # @example
  #   Projects::CreateBlank.call(
  #     account: account, user: user,
  #     github_token: token, repo_name: "fresh-start"
  #   )
  #
  # @spec PROJECT-CREATION-002
  # @spec PROJECT-CREATION-003
  # @spec PROJECT-CREATION-004
  # @spec PROJECT-CREATION-005
  class CreateBlank
    Result = Data.define(:project, :bootstrap_issue_url)

    REPO_NAME_PATTERN = /\A[a-zA-Z0-9._-]+\z/
    RESERVED_REPO_NAMES = %w[. ..].freeze

    class ValidationError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(account:, user:, github_token: nil, github_installation: nil,
      repo_name:, owner: nil, name: nil, description: nil, private: true)
      @account = account
      @user = user
      @github_token = github_token
      @github_installation = github_installation
      @repo_name = repo_name.to_s.strip
      @owner = owner.to_s.strip.presence
      @name = name.to_s.strip.presence
      @description = description.to_s.strip.presence
      @private = private
    end

    def call
      validate_credential!
      validate_repo_name!

      repo_data = client.create_repository(
        @repo_name,
        organization: organization_owner,
        private: @private,
        description: @description
      )

      project = build_project(repo_data)
      project.save!
      apply_post_create_defaults(project)

      Result.new(project: project, bootstrap_issue_url: create_bootstrap_issue(project))
    end

    private

    def validate_credential!
      return if [ @github_token, @github_installation ].compact.size == 1

      raise ValidationError, "exactly one GitHub credential (token or installation) is required"
    end

    # @spec PROJECT-CREATION-005
    def validate_repo_name!
      if @repo_name.blank? || RESERVED_REPO_NAMES.include?(@repo_name) || !@repo_name.match?(REPO_NAME_PATTERN)
        raise ValidationError, "repository name may only contain letters, numbers, periods, hyphens, and underscores"
      end

      if @account.projects.where("lower(owner) = ? AND lower(repo) = ?", resolved_owner.downcase, @repo_name.downcase).exists?
        raise ValidationError, "a project for #{resolved_owner}/#{@repo_name} already exists in this account"
      end
    end

    # Resolves and authorizes the repository owner before any GitHub write.
    # @spec PROJECT-CREATION-004
    def resolved_owner
      return @resolved_owner if defined?(@resolved_owner)

      @resolved_owner = if @github_installation
        authorize_installation_owner!
      else
        authorize_token_owner!
      end
    end

    def authorize_installation_owner!
      login = @github_installation.account_login.to_s.strip
      raise ValidationError, "installation has no account login recorded" if login.blank?
      unless @owner.blank? || @owner.casecmp?(login)
        raise ValidationError, "GitHub App installation can only create repositories under #{login}"
      end

      login
    end

    def authorize_token_owner!
      login = client.authenticated_login.to_s.strip
      raise ValidationError, "could not determine the login for the selected GitHub token" if login.blank?

      return login if @owner.blank? || @owner.casecmp?(login)

      canonical_org = token_organizations_by_login[@owner.downcase]
      return canonical_org if canonical_org

      raise ValidationError, "#{@owner} is not the token's user or one of its organizations"
    end

    def token_organizations_by_login
      @token_organizations_by_login ||= client.organizations
        .filter_map { |org| org.login.to_s.strip.presence }
        .index_by { |login| login.downcase }
    end

    def organization_owner
      return nil if @github_installation

      owner = resolved_owner
      owner == client.authenticated_login.to_s.downcase ? nil : owner
    end

    def client
      @client ||= if @github_installation
        GithubClient.new(
          token: Github::AppInstallation.token_for(
            installation_id: @github_installation.github_installation_id,
            repo_full_name: "#{resolved_owner}/#{@repo_name}"
          ),
          health_endpoint: GithubHealthState.endpoint_for_github_installation(
            @github_installation.github_installation_id
          )
        )
      else
        @github_token.client
      end
    end

    def build_project(repo_data)
      owner_login = repo_data.owner&.login || resolved_owner
      @account.projects.build(
        owner: owner_login,
        repo: repo_data.name,
        name: @name || repo_data.name,
        github_id: repo_data.id,
        default_branch: repo_data.default_branch,
        primary_language: repo_data.language,
        github_token: @github_token,
        github_installation: @github_installation,
        created_by: @user,
        allowed_github_usernames: [ owner_login ],
        creation_origin: "blank",
        setup_status: "pending"
      )
    end

    def apply_post_create_defaults(project)
      TenantConfigurations::ApplyProjectDefaults.call(project)
      ensure_labels_best_effort(project)
    end

    def ensure_labels_best_effort(project)
      Projects::EnsureStandardLabels.call(project: project)
    rescue StandardError => e
      Rails.logger.warn(message: "projects.create_blank.ensure_labels_failed", project_id: project.id, error: e.message)
    end

    # Opens the grill-me bootstrap issue carrying the setup questionnaire.
    # Best-effort: a failure here never fails project creation because every
    # setup channel (chat, intake) remains available without the issue.
    # @spec PROJECT-CREATION-008
    def create_bootstrap_issue(project)
      issue = client.create_issue(
        project.full_name,
        title: bootstrap_issue_title,
        body: bootstrap_issue_body(project),
        labels: [ "needs-manual-setup" ]
      )
      issue&.html_url
    rescue StandardError => e
      Rails.logger.warn(
        message: "projects.create_blank.bootstrap_issue_failed",
        project_id: project.id,
        repo: project.full_name,
        error_class: e.class.name,
        error_message: e.message
      )
      nil
    end

    def bootstrap_issue_title
      "Bootstrap project setup: pick the initial tooling"
    end

    def bootstrap_issue_body(project)
      <<~ISSUE.strip
        `#{project.full_name}` was just created as a blank repository by Paid.
        Before agents can build anything meaningful, the initial tooling
        choices need to be made. Answer the questionnaire below by replying in
        this issue, fill out the setup questionnaire in Paid, or run the chat
        setup (recommended — it captures the most context interactively).

        ---

        #{BuildSetupPrompt.call(project: project)}
      ISSUE
    end
  end
end
