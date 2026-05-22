# frozen_string_literal: true

module ProjectConventions
  module IssueDependencies
    module_function

    def depends_on_line(project:, github_number:, resolved: nil)
      "#{convention_value(project, resolved:).fetch("depends_on_prefix")} ##{github_number}"
    end

    def blocked_by_line(project:, repo:, github_number:, resolved: nil)
      "#{convention_value(project, resolved:).fetch("blocked_by_prefix")} #{repo}##{github_number}"
    end

    def heading(project:, resolved: nil)
      convention_value(project, resolved:).fetch("heading")
    end

    def convention_value(project, resolved: nil)
      resolved || AutomationProfile.for(project:).value("issue_dependency_format")
    end
  end
end
