# frozen_string_literal: true

module Dashboard
  class PrCycleTimeSeries
    DEFAULT_OUTLIER_CUTOFF_HOURS = 24
    WINDOW_DAYS = 90
    CACHE_TTL = 45.seconds

    def self.call(...)
      new(...).call
    end

    def initialize(account:, time_range: "cumulative", outlier_cutoff_hours: DEFAULT_OUTLIER_CUTOFF_HOURS, project_id: nil)
      @account = account
      @time_range = time_range
      @outlier_cutoff_hours = outlier_cutoff_hours
      @project_id = project_id
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute }
    end

    private

    attr_reader :account, :time_range, :outlier_cutoff_hours, :project_id

    def compute
      rows = ActiveRecord::Base.connection.select_all(combined_daily_sql).to_a
      overall_p50 = fetch_overall_p50
      date_range = compute_date_range
      build_series(rows, date_range, overall_p50)
    end

    def cache_key
      [ "dashboard/pr_cycle_time_series", account.id, time_range, outlier_cutoff_hours, project_id ]
    end

    def build_series(rows, date_range, overall_p50)
      by_date = rows.index_by { |r| parse_date(r["merge_date"]) }

      avg_data = {}
      p50_data = {}
      trend_data = {}
      outlier_annotations = {}
      merged_counts = {}
      trend_points = []

      date_range.each do |date|
        row = by_date[date]
        count = row ? row["filtered_count"].to_i : 0

        if count > 0
          avg_h = row["avg_hours"].to_f.round(2)
          p50_h = row["p50_hours"].to_f.round(2)

          avg_data[date] = avg_h
          p50_data[date] = p50_h
          merged_counts[date] = count
          trend_points << { date: date, avg: avg_h, p50: p50_h }
        else
          avg_data[date] = nil
          p50_data[date] = nil
          merged_counts[date] = 0
        end

        if row
          outliers_removed = row["total_count"].to_i - count
          outlier_annotations[date] = outliers_removed if outliers_removed > 0
        end
      end

      compute_trend(trend_points, date_range, trend_data)

      date_set = date_range.to_set
      rows_in_range = rows.select { |r| date_set.include?(parse_date(r["merge_date"])) }

      {
        series: [
          { name: "Average", data: avg_data },
          { name: "Median (p50)", data: p50_data },
          { name: "Trend", data: trend_data }
        ],
        outlier_annotations: outlier_annotations,
        merged_counts: merged_counts,
        summary: build_summary(rows_in_range, overall_p50: overall_p50)
      }
    end

    def build_summary(rows, overall_p50:)
      data_rows = rows.select { |r| r["filtered_count"].to_i > 0 }
      return empty_summary if data_rows.empty?

      total_merged = data_rows.sum { |r| r["filtered_count"].to_i }

      {
        total_merged: total_merged,
        total_days: data_rows.size,
        overall_avg_hours: data_rows.sum { |r| r["avg_hours"].to_f * r["filtered_count"].to_i }.fdiv(total_merged).round(2),
        overall_p50_hours: overall_p50.round(2)
      }
    end

    def empty_summary
      { total_merged: 0, total_days: 0, overall_avg_hours: 0.0, overall_p50_hours: 0.0 }
    end

    def fetch_overall_p50
      ActiveRecord::Base.connection.select_value(overall_p50_sql).to_f
    end

    def overall_p50_sql
      <<~SQL.squish
        SELECT percentile_cont(0.5) WITHIN GROUP (
          ORDER BY EXTRACT(EPOCH FROM (i.github_updated_at - i.github_created_at)) / 3600.0
        )
        FROM issues i
        WHERE i.is_pull_request = true
          AND i.pr_review_phase = 'merged'
          AND i.project_id IN (#{project_ids_sql})
          #{project_scope_filter}
          #{time_filter}
          AND EXTRACT(EPOCH FROM (i.github_updated_at - i.github_created_at)) / 3600.0 <= #{outlier_cutoff_hours}
      SQL
    end

    def compute_trend(points, date_range, trend_data)
      valid = points.reject { |p| p[:avg].nil? || p[:p50].nil? }
      return if valid.size < 3

      xs = valid.map { |v| v[:date].to_time.to_i.to_f }
      ys = valid.map { |v| (v[:avg] + v[:p50]) / 2.0 }

      x_mean = xs.sum / xs.size.to_f
      y_mean = ys.sum / ys.size.to_f

      xs_c = xs.map { |x| x - x_mean }
      ys_c = ys.map { |y| y - y_mean }

      ss_xx = xs_c.sum { |x| x * x }
      ss_xy = xs_c.zip(ys_c).sum { |x, y| x * y }

      return if ss_xx.zero?

      slope = ss_xy / ss_xx
      intercept = y_mean - slope * x_mean

      date_range.each do |date|
        trend_data[date] = (slope * date.to_time.to_i + intercept).round(2)
      end
    end

    def compute_date_range
      end_date = Time.zone.today
      start_date = case time_range
      when "24h" then end_date - 1.day
      when "7d" then end_date - 7.days
      when "30d" then end_date - 30.days
      else end_date - (WINDOW_DAYS - 1).days
      end
      (start_date..end_date).to_a
    end

    def combined_daily_sql
      # Use a CTE so the base table is scanned once; totals and filtered aggregations
      # are then two separate aggregations over the CTE rather than two SQL round-trips.
      <<~SQL
        WITH base AS (
          SELECT DATE(i.github_updated_at) AS merge_date,
                 EXTRACT(EPOCH FROM (i.github_updated_at - i.github_created_at)) / 3600.0 AS cycle_hours
          FROM issues i
          WHERE i.is_pull_request = true
            AND i.pr_review_phase = 'merged'
            AND i.project_id IN (#{project_ids_sql})
            #{project_scope_filter}
            #{time_filter}
        ),
        totals AS (
          SELECT merge_date, COUNT(*) AS total_count
          FROM base
          GROUP BY merge_date
        ),
        filtered AS (
          SELECT merge_date,
                 COUNT(*) AS filtered_count,
                 AVG(cycle_hours)::numeric AS avg_hours,
                 percentile_cont(0.5) WITHIN GROUP (ORDER BY cycle_hours) AS p50_hours
          FROM base
          WHERE cycle_hours <= #{outlier_cutoff_hours}
          GROUP BY merge_date
        )
        SELECT t.merge_date,
               t.total_count,
               COALESCE(f.filtered_count, 0) AS filtered_count,
               f.avg_hours,
               f.p50_hours
        FROM totals t
        LEFT JOIN filtered f USING (merge_date)
        ORDER BY t.merge_date
      SQL
    end

    def project_scope_filter
      return "" unless project_id

      "AND i.project_id = #{ActiveRecord::Base.connection.quote(project_id)}"
    end

    def time_filter
      case time_range
      when "24h" then "AND DATE(i.github_updated_at) >= #{quoted_date(Time.zone.today - 1.day)}"
      when "7d" then "AND DATE(i.github_updated_at) >= #{quoted_date(Time.zone.today - 7.days)}"
      when "30d" then "AND DATE(i.github_updated_at) >= #{quoted_date(Time.zone.today - 30.days)}"
      else ""
      end
    end

    def quoted_date(date)
      ActiveRecord::Base.connection.quote(date.to_s)
    end

    def parse_date(value)
      case value
      when Date then value
      when String then Date.parse(value)
      when Time then value.to_date
      else Date.parse(value.to_s)
      end
    end

    def project_ids_sql
      Project.where(account_id: account.id).select(:id).to_sql
    end
  end
end
