# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-006 ONBOARD-CHAT-011
  class CreateProject < BaseTool
    authorize :create?, ->(_args) { Project.new(account: current_user.account) }, policy_class: ProjectPolicy

    def self.tool_name = "create_project"
    def self.write_operation? = true
    def self.description = "Connect an existing GitHub repository or create a blank GitHub repository after confirmation."

    def self.input_schema
      { type: "object", properties: {
        mode: { type: "string", enum: %w[connect_existing create_blank] }, owner: { type: "string" }, repo: { type: "string" }, name: { type: "string" },
        github_token_id: { type: "integer" }, github_installation_id: { type: "integer" }, private: { type: "boolean" }, confirmed: { type: "boolean" }
      }, required: %w[mode repo confirmed] }
    end

    def perform(mode:, repo:, confirmed:, owner: nil, name: nil, github_token_id: nil, github_installation_id: nil, private: true)
      raise ArgumentError, "Confirmation required: set confirmed=true to create a project" unless confirmed

      project = if mode == "create_blank"
        Projects::CreateBlank.call(account:, user:, github_token: token(github_token_id), github_installation: installation(github_installation_id), repo_name: repo, owner:, name:, private:).project
      elsif mode == "connect_existing"
        connect_existing(owner:, repo:, name:, github_token_id:, github_installation_id:)
      else
        raise ArgumentError, "mode must be connect_existing or create_blank"
      end
      if account.onboarding_steps.exists?(step: "first_project", status: "in_progress")
        Onboarding::CompleteStep.call(account:, step: "first_project", metadata: { project_id: project.id })
      end
      project.attributes.slice("id", "name", "owner", "repo", "default_branch", "creation_origin")
    end

    private

    def connect_existing(owner:, repo:, name:, github_token_id:, github_installation_id:)
      github_token = token(github_token_id)
      github_installation = installation(github_installation_id)
      unless [ github_token, github_installation ].compact.one?
        raise ArgumentError, "exactly one GitHub credential (token or installation) is required"
      end

      resolved_owner = owner.presence || credential_owner(github_token:, github_installation:)
      project = account.projects.build(owner: resolved_owner, repo:, name:, github_token:, github_installation:, created_by: user, allowed_github_usernames: [ resolved_owner ])
      data = project.client.repository("#{resolved_owner}/#{repo}")
      project.assign_attributes(github_id: data.id, name: name.presence || data.name, default_branch: data.default_branch, primary_language: data.language, creation_origin: "connected")
      project.save!
      project
    end

    def credential_owner(github_token:, github_installation:)
      owner = github_installation&.account_login.presence || github_token&.client&.authenticated_login.to_s.strip.presence
      raise ArgumentError, "could not determine the owner for the selected GitHub credential" if owner.blank?

      owner
    end

    def token(id)
      return if id.blank?

      account.github_tokens.active.find(id)
    end

    def installation(id)
      return if id.blank?

      account.github_installations.active.find(id)
    end
  end
end
