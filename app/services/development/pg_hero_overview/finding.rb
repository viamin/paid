# frozen_string_literal: true

require "digest"

module Development
  module PgHeroOverview
    # One normalized Overview warning. The key is the stable identity minus
    # the database (for example "slow_query/123456"); identity joins database
    # and key. fingerprint changes only when the observed evidence changes,
    # so unchanged findings never rewrite their issue body.
    #
    # @spec RAILS-CONTROL-PLANE-027
    Finding = Data.define(:type, :key, :title, :observed, :observed_at, :database,
      :persistence_required, :category) do
      def identity = "#{database}/#{key}"

      def fingerprint
        Digest::SHA256.hexdigest("#{type}|#{key}|#{observed.to_json}")
      end
    end
  end
end
