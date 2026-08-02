# frozen_string_literal: true

module HealthChecks
  # Stores the cached Result the project health page reads. The daily sweep is
  # the single source of truth: the page never runs checks live, it reads here.
  # TTL is set a little longer than the daily cadence so a sweep that briefly
  # slips does not leave the page empty at the boundary.
  class Cache
    KEY_PREFIX = "health_checks/project"
    TTL = 26.hours

    class << self
      def write(project, result)
        Rails.cache.write(key(project), result, expires_in: TTL)
      end

      def read(project)
        Rails.cache.read(key(project))
      end

      def delete(project)
        Rails.cache.delete(key(project))
      end

      private

      def key(project)
        "#{KEY_PREFIX}/#{project.id}"
      end
    end
  end
end
