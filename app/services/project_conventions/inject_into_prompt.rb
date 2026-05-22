# frozen_string_literal: true

module ProjectConventions
  class InjectIntoPrompt
    SECTION_HEADING = "## Repository Automation Conventions"

    def self.call(...)
      new(...).call
    end

    attr_reader :prompt, :project

    def initialize(prompt:, project:)
      @prompt = prompt.to_s
      @project = project
    end

    def call
      return prompt if prompt.include?(SECTION_HEADING)

      section = build_section
      return prompt if section.blank?

      "#{prompt.rstrip}\n\n#{section}\n"
    end

    private

    def build_section
      profile = AutomationProfile.for(project:)
      lines = [
        SECTION_HEADING,
        "",
        "Treat required items as hard requirements. Treat guidance items as preferred defaults unless the user explicitly overrides them.",
        "",
        commit_line(profile),
        pr_line(profile),
        dependency_line(profile)
      ].compact

      lines.join("\n")
    end

    def commit_line(profile)
      style = profile.value("commit_style")
      strength = profile.required?("commit_style") ? "Required" : "Guidance"

      if style["type"] == "plain"
        fallback = style["fallback_subject"].presence || "Apply agent changes"
        "- Commit subjects: #{strength}. Use plain subjects. Fallback subject: `#{fallback}`."
      else
        allowed_types = profile.allowed_types("commit_style")
        allowed_text = allowed_types.any? ? " Allowed types: `#{allowed_types.join("`, `")}`." : ""
        default_type = style["default_type"].presence || "feat"
        "- Commit subjects: #{strength}. Use conventional commits with default type `#{default_type}`.#{allowed_text}"
      end
    end

    def pr_line(profile)
      style = profile.value("pr_title_style")
      strength = profile.required?("pr_title_style") ? "Required" : "Guidance"
      release_text = profile.significant_for_release? ? " Merged PR titles affect release automation." : ""

      if style["type"] == "plain"
        fallback = style["fallback_subject"].presence || "Agent changes"
        "- PR titles: #{strength}. Use plain titles. Fallback title: `#{fallback}`.#{release_text}"
      else
        allowed_types = profile.allowed_types("pr_title_style")
        allowed_text = allowed_types.any? ? " Allowed types: `#{allowed_types.join("`, `")}`." : ""
        default_type = style["default_type"].presence || "feat"
        "- PR titles: #{strength}. Use conventional commits with default type `#{default_type}`.#{allowed_text}#{release_text}"
      end
    end

    def dependency_line(profile)
      format = profile.value("issue_dependency_format")
      strength = profile.required?("issue_dependency_format") ? "Required" : "Guidance"

      "- Issue and comment dependencies: #{strength}. Use heading `#{format["heading"]}` and explicit lines like `#{format["depends_on_prefix"]} #123` and `#{format["blocked_by_prefix"]} owner/repo#123`."
    end
  end
end
