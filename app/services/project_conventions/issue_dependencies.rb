# frozen_string_literal: true

module ProjectConventions
  module IssueDependencies
    module_function

    def depends_on_line(project:, github_number:)
      "#{format(project).fetch("depends_on_prefix")} ##{github_number}"
    end

    def blocked_by_line(project:, repo:, github_number:)
      "#{format(project).fetch("blocked_by_prefix")} #{repo}##{github_number}"
    end

    def heading(project:)
      format(project).fetch("heading")
    end

    def format(project)
      Resolve.call(project:, key: "issue_dependency_format").fetch(:value)
    end
  end
end
