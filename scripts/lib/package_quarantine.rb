# frozen_string_literal: true

require "time"

# Holds back releases that are too new to trust.
#
# Automated version bumps are a supply-chain attack surface: a compromised
# release is usually detected and yanked within hours of publication. Refusing
# to adopt anything younger than a minimum age turns that detection window into
# a safety margin, at the cost of adopting real releases a few days late.
#
# @spec TOOLCHAIN-PIN-050
class PackageQuarantine
  attr_reader :minimum_age_hours

  def initialize(minimum_age_hours:, skip: false, clock: -> { Time.now })
    @minimum_age_hours = minimum_age_hours
    @skip = skip || minimum_age_hours.zero?
    @clock = clock
  end

  def skip? = @skip

  def age_hours(published_at)
    ((@clock.call - published_at) / 3600).round(1)
  end

  # A release whose publication time is unknown is not held: the registry that
  # served the version could not tell us when it landed, and blocking every such
  # pin would stall updates rather than make them safer.
  def held?(published_at)
    return false if skip?
    return false if published_at.nil?

    age_hours(published_at) < minimum_age_hours
  end

  # The same policy expressed in whole days, for resolvers that enforce a
  # cooldown natively (Bundler's `--cooldown`). Rounding up matters: a 73-hour
  # quarantine must not be satisfied by a three-day cooldown, so a partial day
  # is never rounded away. Zero means "explicitly disabled", which Bundler
  # treats as an override of any per-source or global setting rather than as
  # an absent flag.
  #
  # @spec TOOLCHAIN-PIN-052
  def cooldown_days
    return 0 if skip?

    (minimum_age_hours / 24.0).ceil
  end

  # Human-readable reason a release was held, or nil when it was not.
  def hold_reason(label, version, published_at)
    return nil unless held?(published_at)

    "#{label} #{version} (#{age_hours(published_at)}h old, minimum: #{minimum_age_hours}h)"
  end
end
