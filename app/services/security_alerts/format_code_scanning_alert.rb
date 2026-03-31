# frozen_string_literal: true

module SecurityAlerts
  # Builds human-readable title and body strings for a CodeQL code scanning
  # alert so they can be stored in a synthetic Issue record.
  class FormatCodeScanningAlert
    def self.title(alert)
      new.title(alert)
    end

    def self.body(alert)
      new.body(alert)
    end

    def title(alert)
      parts = [ "[Security] CodeQL:" ]
      parts << alert[:rule_description] if alert[:rule_description]
      parts << "(#{alert[:severity]})" if alert[:severity]
      parts << "— #{alert_identifier(alert)}"
      parts.join(" ")
    end

    def body(alert)
      lines = []
      lines << "## Code Scanning Alert ##{alert[:number]}"
      lines << ""
      lines << "**Severity:** #{alert[:severity]}" if alert[:severity]
      lines << "**Rule:** #{alert[:rule_id]}" if alert[:rule_id]
      lines << "**Tool:** #{alert[:tool_name]}" if alert[:tool_name]
      lines << "**Summary:** #{alert[:summary]}" if alert[:summary]
      lines << ""
      lines << "### Goal"
      lines << ""
      lines << "Fix the code scanning alert described above. Review the flagged code"
      lines << "for the identified vulnerability and apply the recommended remediation."
      lines << "Run the test suite to verify the fix does not introduce regressions."
      lines << ""
      lines << "[View alert on GitHub](#{alert[:html_url]})" if alert[:html_url]
      lines.join("\n")
    end

    private

    def alert_identifier(alert)
      "code-scanning-alert-#{alert[:number]}"
    end
  end
end
