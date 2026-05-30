# frozen_string_literal: true

module Tools
  class ReadRepoFile < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    MAX_FILE_SIZE_BYTES = 200 * 1024

    def self.tool_name = "read_repo_file"

    def self.description
      "Read the contents of a file in a project's GitHub repository."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          path: { type: "string", description: "File path within the repository" },
          ref: { type: "string", description: "Git ref (branch, tag, or SHA). Defaults to HEAD.", default: "HEAD" }
        },
        required: %w[project_id path]
      }
    end

    def perform(project_id:, path:, ref: "HEAD")
      project = project_for(project_id)
      client = resolve_client(project)

      data = client.contents(project.full_name, path: path, ref: ref)

      return error_result("Path is a directory, not a file", project) if data.is_a?(Array)
      return error_result("Path is not a file", project) unless data.type == "file"

      return error_result("File is empty", project, path: path) unless data.content.present?

      raw = Base64.decode64(data.content)
      return error_result("File exceeds #{MAX_FILE_SIZE_BYTES / 1024}KB size limit", project, path: path) if raw.bytesize > MAX_FILE_SIZE_BYTES
      return error_result("File appears to be binary", project, path: path) unless utf8_text?(raw)

      {
        path: data.path,
        size: raw.bytesize,
        encoding: "utf-8",
        content: raw,
        identity: identity_label(project)
      }
    rescue GithubClient::NotFoundError
      { error: "File not found: #{path}", identity: identity_label(project) }
    end

    private

    def resolve_client(project)
      client = project.client
      raise ArgumentError, "Project has no GitHub credentials configured" unless client

      client
    end

    def identity_label(project)
      if project.github_installation.present?
        "github-app:#{project.github_installation.github_installation_id}"
      elsif project.github_token.present?
        "project-token:#{project.github_token.name}"
      else
        "unknown"
      end
    end

    def utf8_text?(raw)
      raw.dup.force_encoding("UTF-8").valid_encoding?
    end

    def error_result(message, project, path: nil)
      result = { error: message, identity: identity_label(project) }
      result[:path] = path if path
      result
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
