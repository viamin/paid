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
      repo_client = resolve_repo_read_client(project)
      client = repo_client.client

      data = client.contents(project.full_name, path: path, ref: ref)

      return error_result("Path is a directory, not a file", repo_client.identity) if data.is_a?(Array)
      return error_result("Path is not a file", repo_client.identity) unless data.type == "file"

      return error_result("File exceeds #{MAX_FILE_SIZE_BYTES / 1024}KB size limit", repo_client.identity, path: path) if data.size > MAX_FILE_SIZE_BYTES
      return error_result("File is empty", repo_client.identity, path: path) unless data.content.present?

      raw = Base64.decode64(data.content)
      return error_result("File appears to be binary", repo_client.identity, path: path) unless utf8_text?(raw)

      {
        path: data.path,
        size: raw.bytesize,
        encoding: "utf-8",
        content: raw,
        identity: repo_client.identity
      }
    rescue GithubClient::NotFoundError
      { error: "File not found: #{path}", identity: repo_client.identity }
    end

    private

    def utf8_text?(raw)
      return false if raw.include?("\x00")

      raw.dup.force_encoding("UTF-8").valid_encoding?
    end

    def error_result(message, identity, path: nil)
      result = { error: message, identity: identity }
      result[:path] = path if path
      result
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
