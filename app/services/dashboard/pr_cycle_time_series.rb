# frozen_string_literal: true

module Dashboard
  class PrCycleTimeSeries
    DEFAULT_OUTLIER_CUTOFF_HOURS = 24
    WINDOW_DAYS = 90

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
      rows = ActiveRecord::Base.connection.select_all(daily_cycle_time_sql).to_a
      all_rows = ActiveRecord::Base.connection.select_all(all_daily_counts_sql).to_a
      overall_p50 = fetch_overall_p50
      date_range = compute_date_range
      build_series(rows, all_rows, date_range, overall_p50)
    end

    private

    attr_reader :account, :time_range, :outlier_cutoff_hours, :project_id

    def build_series(filtered_rows, all_rows, date_range, overall_p50)
      filtered_by_date = filtered_rows.index_by { |r| parse_date(r["merge_date"]) }
      all_by_date = all_rows.index_by { |r| parse_date(r["merge_date"]) }

      avg_data = {}
      p50_data = {}
      trend_data = {}
      outlier_annotations = {}
      merged_counts = {}
      trend_points = []

      date_range.each do |date|
        fr = filtered_by_date[date]
        ar = all_by_date[date]

        if fr
          avg_h = fr["avg_hours"].to_f.round(2)
          p50_h = fr["p50_hours"].to_f.round(2)
          count = fr["filtered_count"].to_i

          avg_data[date] = avg_h
          p50_data[date] = p50_h
          merged_counts[date] = count
          trend_points << { date: date, avg: avg_h, p50: p50_h }
        else
          avg_data[date] = nil
          p50_data[date] = nil
          merged_counts[date] = 0
        end

        if ar
          total = ar["total_count"].to_i
          filtered = filtered_by_date[date]&.fetch("filtered_count", 0).to_i
          outliers_removed = total - filtered
          if outliers_removed > 0
            outlier_annotations[date] = outliers_removed
          end
        end
      end

      compute_trend(trend_points, date_range, trend_data)

      {
        series: [
          { name: "Average", data: avg_data },
          { name: "Median (p50)", data: p50_data },
          { name: "Trend", data: trend_data }
        ],
        outlier_annotations: outlier_annotations,
        merged_counts: merged_counts,
        summary: build_summary(filtered_rows, overall_p50: overall_p50)
      }
    end

    def build_summary(rows, overall_p50:)
      return empty_summary if rows.empty?

      total_merged = rows.sum { |r| r["filtered_count"].to_i }

      {
        total_merged: total_merged,
        total_days: rows.size,
        overall_avg_hours: rows.sum { |r| r["avg_hours"].to_f * r["filtered_count"].to_i }.fdiv(total_merged).round(2),
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
      when "7d" then end_date - 6.days
      when "30d" then end_date - 29.days
      else end_date - (WINDOW_DAYS - 1).days
      end
      (start_date..end_date).to_a
    end

    def daily_cycle_time_sql
      <<~SQL.squish
        SELECT DATE(i.github_updated_at) AS merge_date,
               AVG(EXTRACT(EPOCH FROM (i.github_updated_at - i.github_created_at)) / 3600.0)::numeric AS avg_hours,
               percentile_cont(0.5) WITHIN GROUP (
                 ORDER BY EXTRACT(EPOCH FROM (i.github_updated_at - i.github_created_at)) / 3600.0
               ) AS p50_hours,
               COUNT(*) AS filtered_count
        FROM issues i
        WHERE i.is_pull_request = true
          AND i.pr_review_phase = 'merged'
          AND i.project_id IN (#{project_ids_sql})
          #{project_scope_filter}
          #{time_filter}
          AND EXTRACT(EPOCH FROM (i.github_updated_at - i.github_created_at)) / 3600.0 <= #{outlier_cutoff_hours}
        GROUP BY DATE(i.github_updated_at)
        ORDER BY merge_date
      SQL
    end

    def all_daily_counts_sql
      <<~SQL.squish
        SELECT DATE(i.github_updated_at) AS merge_date,
               COUNT(*) AS total_count
        FROM issues i
        WHERE i.is_pull_request = true
          AND i.pr_review_phase = 'merged'
          AND i.project_id IN (#{project_ids_sql})
          #{project_scope_filter}
          #{time_filter}
        GROUP BY DATE(i.github_updated_at)
        ORDER BY merge_date
      SQL
    end

    def project_scope_filter
      return "" unless project_id

      "AND i.project_id = #{ActiveRecord::Base.connection.quote(project_id)}"
    end

    def time_filter
      case time_range
      when "24h" then "AND i.github_updated_at >= #{quoted_time(24.hours.ago)}"
      when "7d" then "AND i.github_updated_at >= #{quoted_time(7.days.ago)}"
      when "30d" then "AND i.github_updated_at >= #{quoted_time(30.days.ago)}"
      else ""
      end
    end

    def quoted_time(time)
      ActiveRecord::Base.connection.quote(time)
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
