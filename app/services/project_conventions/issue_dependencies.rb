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

    # Appends only missing dependency lines and preserves any content after a
    # mid-body dependency heading.
    def append_dependency_lines(project:, github_numbers:, body:, resolved: nil)
      lines = new_dependency_lines(project:, github_numbers:, body:, resolved:)
      return body if lines.empty?

      dependency_heading = heading(project:, resolved:)
      return insert_under_heading(body:, heading: dependency_heading, lines:) if body.include?(dependency_heading)

      [ body, dependency_heading, lines.join("\n") ].reject(&:blank?).join("\n\n")
    end

    def convention_value(project, resolved: nil)
      resolved || AutomationProfile.for(project:).value("issue_dependency_format")
    end

    def new_dependency_lines(project:, github_numbers:, body:, resolved:)
      github_numbers.filter_map do |github_number|
        line = depends_on_line(project:, github_number:, resolved:)
        "- #{line}" unless body.match?(/\b#{Regexp.escape(line)}\b/)
      end
    end

    def insert_under_heading(body:, heading:, lines:)
      heading_start = body.index(heading)
      remainder = body[(heading_start + heading.length)..].to_s
      section, trailing = remainder.split(/(?=\n\s*#)/, 2)
      updated_section = [ section.rstrip, lines.join("\n") ].reject(&:blank?).join("\n")
      [ body[0...heading_start].rstrip, heading, updated_section, trailing.to_s.lstrip ]
        .reject(&:blank?).join("\n\n")
    end
    private_class_method :new_dependency_lines, :insert_under_heading
  end
end
