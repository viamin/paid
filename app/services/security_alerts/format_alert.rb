# frozen_string_literal: true

module SecurityAlerts
  # Builds human-readable title and body strings for a Dependabot alert
  # so they can be stored in a synthetic Issue record.
  class FormatAlert
    def self.title(alert)
      new.title(alert)
    end

    def self.body(alert)
      new.body(alert)
    end

    def title(alert)
      parts = [ "[Security]" ]
      parts << "Upgrade #{alert[:package_name]}" if alert[:package_name]
      parts << "to #{alert[:patched_version]}" if alert[:patched_version]
      parts << "(#{alert[:severity]})" if alert[:severity]
      parts << "— #{alert_identifier(alert)}"
      parts.join(" ")
    end

    def body(alert)
      lines = []
      # rubocop friendly: #{ is Ruby interpolation, so ##{n} yields "#1" not "##1"
      lines << "## Dependabot Security Alert ##{alert[:number]}"
      lines << ""
      lines << "**Severity:** #{alert[:severity]}" if alert[:severity]
      if alert[:package_name]
        package_label = alert[:package_name]
        package_label = "#{package_label} (#{alert[:package_ecosystem]})" if alert[:package_ecosystem]
        lines << "**Package:** #{package_label}"
      end
      lines << "**Patched version:** #{alert[:patched_version]}" if alert[:patched_version]
      lines << "**Summary:** #{alert[:summary]}" if alert[:summary]
      lines << ""
      lines << "### Goal"
      lines << ""

      if alert[:patched_version] && alert[:package_name]
        lines << "Upgrade `#{alert[:package_name]}` to version `#{alert[:patched_version]}` or later"
        lines << "to resolve this security vulnerability. Run the test suite to verify"
        lines << "the upgrade does not introduce regressions."
      else
        lines << "Fix the security vulnerability described above."
      end

      lines << ""
      lines << "[View alert on GitHub](#{alert[:html_url]})" if alert[:html_url]
      lines.join("\n")
    end

    private

    def alert_identifier(alert)
      "dependabot-alert-#{alert[:number]}"
    end
  end
end
