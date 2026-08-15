# rbs_inline: enabled

require "json"
require "rack/utils"

module SolidObjects
  class Web
    # The methods a view may call. Everything a template prints goes through
    # `h`, because an actor id, an operation name, and an exception message are
    # all application supplied strings that reach this page unchanged.
    module Helpers
      # Only these survive a page link. A filter an operator set stays set when
      # they turn the page; anything else the query string carries does not
      # come back.
      FORWARDED_PARAMS = %w[actor_type actor_id status per_page].freeze
      TRUNCATION_LIMIT = 2_000

      # @rbs (untyped) -> String
      def h(text)
        ::Rack::Utils.escape_html(text.to_s)
      end

      # @rbs () -> String
      def root_path
        env["SCRIPT_NAME"].to_s
      end

      # @rbs (String) -> String
      def path_to(path)
        "#{root_path}#{path}"
      end

      # @rbs () -> String
      def current_path
        request.path_info
      end

      # @rbs (String) -> bool
      def current_tab?(path)
        return current_path == "/" if path == "/"

        current_path.start_with?(path)
      end

      # @rbs () -> Hash[String, String]
      def tabs
        Web.tabs
      end

      # @rbs () -> String?
      def csp_nonce
        env[Web::NONCE_KEY]
      end

      # @rbs () -> String
      def csrf_tag
        %(<input type="hidden" name="authenticity_token" value="#{h(env[Web::CSRF_TOKEN_KEY])}" />)
      end

      # @rbs (String) -> String
      def form_to(path)
        %(<form method="post" action="#{h(path_to(path))}">#{csrf_tag})
      end

      # @rbs (untyped) -> String
      def relative_time(time)
        return "&mdash;" unless time

        stamp = time.getutc.iso8601
        %(<time datetime="#{stamp}" title="#{stamp}">#{h(stamp)}</time>)
      end

      # @rbs (untyped) -> String
      def number(value)
        h(value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse)
      end

      # @rbs (Numeric?) -> String
      def duration(seconds)
        return "&mdash;" unless seconds

        return "#{h(format("%.3f", seconds))} s" if seconds < 60

        h("#{(seconds / 60).floor} min #{(seconds % 60).round} s")
      end

      # @rbs (untyped, ?Integer) -> String
      def json_block(value)
        return "&mdash;" if value.nil?

        %(<pre class="payload">#{h(truncate(JSON.pretty_generate(value)))}</pre>)
      rescue JSON::GeneratorError, TypeError
        %(<pre class="payload">#{h(truncate(value.inspect))}</pre>)
      end

      # @rbs (String, ?Integer) -> String
      def truncate(text, limit = TRUNCATION_LIMIT)
        return text if text.length <= limit

        "#{text[0, limit]}…"
      end

      # @rbs (String?) -> String
      def status_label(status)
        %(<span class="status status-#{h(status)}">#{h(status)}</span>)
      end

      # @rbs (untyped) -> String
      def actor_label(record)
        "#{h(record.actor_type)} / #{h(record.actor_id)}"
      end

      # @rbs (untyped) -> String
      def instance_link(instance)
        %(<a href="#{h(path_to("/instances/#{instance.id}"))}">#{actor_label(instance)}</a>)
      end

      # @rbs (?Hash[String, untyped]) -> String
      def query_string(overrides = {})
        merged = FORWARDED_PARAMS
          .to_h { |name| [ name, url_params(name) ] }
          .merge(overrides.transform_keys(&:to_s))
          .reject { |_name, value| value.nil? || value.to_s.empty? }
        return "" if merged.empty?

        "?#{merged.map { |name, value| "#{::Rack::Utils.escape(name)}=#{::Rack::Utils.escape(value.to_s)}" }.join("&")}"
      end

      # @rbs (?Hash[String, untyped]) -> String
      def page_link(overrides = {})
        h("#{path_to(current_path)}#{query_string(overrides)}")
      end

      # @rbs (Instance) -> String
      def lease_state(instance)
        return "paused" if instance.paused_at
        return "idle" unless instance.activation_owner_id
        return "idle" unless instance.activation_expires_at

        (instance.activation_expires_at > statistics.now) ? "activated" : "expired"
      end

      # @rbs () -> Statistics
      def statistics
        @statistics ||= Statistics.new
      end

      # @rbs (untyped) -> Paginator
      def paginate(relation)
        Paginator.new(relation:, page: url_params("page"), per_page: url_params("per_page"))
      end

      # An unrecognized filter falls back to the default rather than returning
      # nothing, so a hand edited query string cannot make a page look empty.
      # @rbs (Array[String], ?default: String?) -> String?
      def filter_value(allowed, default: nil)
        value = url_params("status")
        allowed.include?(value) ? value : default
      end

      # @rbs () -> Instance
      def find_instance
        instance = Instance.find_by(id: route_params(:id))
        halt(404) unless instance

        instance
      end

      # @rbs () -> untyped
      def filtered_instances
        relation = Instance.order(updated_at: :desc, id: :desc)
        actor_type = url_params("actor_type")
        relation = relation.where(actor_type:) unless actor_type.to_s.empty?
        actor_id = url_params("actor_id")
        return relation if actor_id.to_s.empty?

        relation.where(
          Instance.arel_table[:actor_id].matches("%#{Instance.sanitize_sql_like(actor_id)}%")
        )
      end

      # @rbs (String) -> untyped
      def mailbox_messages(membership)
        membership_model = (membership == "claimed") ? ClaimedMessage : ReadyMessage
        Message
          .where(id: membership_model.select(:message_id))
          .order(available_at: :asc, id: :asc)
      end

      # Chart data travels in an attribute rather than an inline script block,
      # so the page needs no script-src exception and an actor type cannot
      # close the attribute and open a tag.
      #
      # The container is not decoration. Chart.js measures a responsive canvas
      # against its parent, so the parent has to have a height of its own; a
      # panel that sizes to its children would grow a little on every redraw.
      # @rbs (String, untyped) -> String
      def chart(name, values)
        return "" unless Web.charts?

        %(<div class="chart-frame"><canvas data-chart="#{h(name)}" ) +
          %(data-chart-values='#{h(JSON.generate(values))}'></canvas></div>)
      end

      # A vendored copy is a path below the mount; a CDN copy is an absolute
      # URL and is left alone.
      # @rbs () -> String
      def chart_library_source
        url = Web.chart_library_url.to_s
        url.include?("//") ? url : path_to(url)
      end

      # @rbs () -> String
      def chart_library_integrity_attributes
        integrity = Web.chart_library_integrity
        return "" unless integrity

        %( integrity="#{h(integrity)}" crossorigin="anonymous" referrerpolicy="no-referrer")
      end

      # @rbs () -> String
      def environment_name
        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      end
    end
  end
end
