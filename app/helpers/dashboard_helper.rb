# frozen_string_literal: true

module DashboardHelper
  def format_duration(seconds)
    return "--" unless seconds && seconds > 0

    if seconds >= 86400
      "#{seconds / 86400}d #{(seconds % 86400) / 3600}h"
    elsif seconds >= 3600
      "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
    elsif seconds >= 60
      "#{seconds / 60}m #{seconds % 60}s"
    else
      "#{seconds}s"
    end
  end
end
