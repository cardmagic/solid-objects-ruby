# rbs_inline: enabled

module SolidObjects
  class Web
    # The pages. Each route states the administration policy it needs, and
    # `call` asks that policy before the handler runs, so a page cannot read
    # the actor tables on behalf of an unauthorized request.
    class Application
      extend Router

      SCRIPT_PLACEHOLDER = "!script-src!"
      CONTENT_SECURITY_POLICY = [
        "default-src 'self'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "img-src 'self' data:",
        "style-src 'self'",
        "script-src #{SCRIPT_PLACEHOLDER}",
        "connect-src 'self'",
        "object-src 'none'"
      ].join("; ").freeze

      MAILBOX_MEMBERSHIPS = %w[ready claimed].freeze
      RECENT_LIMIT = 10
      CHART_TYPE_LIMIT = 12

      head "/", policy: { action: "index", resource: "dashboard" } do
        # The cheapest liveness check available: it proves the dashboard can
        # reach the database the actors run on, and returns no body.
        ReadyMessage.count
        ""
      end

      get "/", policy: { action: "index", resource: "dashboard" } do
        @statistics = statistics.to_h
        @processes = Process.order(last_heartbeat_at: :desc).limit(RECENT_LIMIT)
        @dead_letters = DeadLetter.order(last_failed_at: :desc, id: :desc).limit(RECENT_LIMIT)
        # The only chart that costs its own query, and the only one the poller
        # cannot refresh, because the other two read what `/stats` already
        # returns. Bounded so a runtime with many actor types draws a readable
        # chart rather than every type it has ever seen.
        @instances_by_type = Instance
          .group(:actor_type)
          .order(Arel.sql("COUNT(*) DESC"))
          .limit(CHART_TYPE_LIMIT)
          .count
        erb(:dashboard)
      end

      get "/stats", policy: { action: "index", resource: "dashboard" } do
        json(statistics.to_h)
      end

      get "/instances", policy: { action: "index", resource: "instances" } do
        @paginator = paginate(filtered_instances)
        # Suggestions come from the registry rather than a DISTINCT over the
        # instances table, which no adapter can answer from an index. The field
        # stays free text, so an actor type that is no longer registered is
        # still reachable.
        @actor_types = SolidObjects.registry.to_h.keys.sort
        erb(:instances)
      end

      get "/instances/:id", policy: { action: "show", resource: "instances" } do
        @instance = find_instance
        @ready_messages = @instance.messages
          .where(id: ReadyMessage.select(:message_id))
          .order(sequence: :asc)
          .limit(RECENT_LIMIT)
        @claimed_messages = @instance.messages
          .where(id: ClaimedMessage.select(:message_id))
          .order(sequence: :asc)
          .limit(RECENT_LIMIT)
        @recent_messages = @instance.messages.order(sequence: :desc).limit(RECENT_LIMIT)
        @reminders = Reminder.where(instance_id: @instance.id).order(next_run_at: :asc).limit(RECENT_LIMIT)
        @effects = Effect.where(instance_id: @instance.id).order(id: :desc).limit(RECENT_LIMIT)
        @broadcasts = Broadcast.where(instance_id: @instance.id).order(id: :desc).limit(RECENT_LIMIT)
        @dead_letters = DeadLetter.where(instance_id: @instance.id).order(last_failed_at: :desc).limit(RECENT_LIMIT)
        erb(:instance)
      end

      # Pausing stops the activation manager from claiming the instance again.
      # A pass already in flight finishes its turn, and a synchronous caller
      # waiting on this instance times out rather than being answered, so this
      # is an operator brake and not a delivery guarantee.
      post "/instances/:id/pause", policy: { action: "pause", resource: "instances" } do
        instance = find_instance
        instance.update!(paused_at: SolidObjects.database_adapter.database_now)
        redirect("/instances/#{instance.id}")
      end

      post "/instances/:id/resume", policy: { action: "resume", resource: "instances" } do
        instance = find_instance
        instance.update!(paused_at: nil)
        redirect("/instances/#{instance.id}")
      end

      get "/mailbox", policy: { action: "index", resource: "messages" } do
        @membership = filter_value(MAILBOX_MEMBERSHIPS, default: "ready")
        @paginator = paginate(mailbox_messages(@membership))
        erb(:mailbox)
      end

      get "/messages/:id", policy: { action: "show", resource: "messages" } do
        @message = Message.find_by(id: route_params(:id))
        halt(404) unless @message
        erb(:message)
      end

      get "/reminders", policy: { action: "index", resource: "reminders" } do
        @status = filter_value(Statistics::REMINDER_STATUSES)
        relation = Reminder.order(next_run_at: :asc, id: :asc)
        @paginator = paginate(@status ? relation.where(status: @status) : relation)
        erb(:reminders)
      end

      get "/effects", policy: { action: "index", resource: "effects" } do
        @status = filter_value(Statistics::EFFECT_STATUSES)
        relation = Effect.order(id: :desc)
        @paginator = paginate(@status ? relation.where(status: @status) : relation)
        erb(:effects)
      end

      get "/broadcasts", policy: { action: "index", resource: "broadcasts" } do
        @status = filter_value(Statistics::BROADCAST_STATUSES)
        relation = Broadcast.order(id: :desc)
        @paginator = paginate(@status ? relation.where(status: @status) : relation)
        erb(:broadcasts)
      end

      get "/dead_letters", policy: { action: "index", resource: "dead_letters" } do
        @paginator = paginate(DeadLetter.order(last_failed_at: :desc, id: :desc))
        erb(:dead_letters)
      end

      get "/dead_letters/:id", policy: { action: "show", resource: "dead_letters" } do
        @dead_letter = DeadLetter.find_by(id: route_params(:id))
        halt(404) unless @dead_letter
        erb(:dead_letter)
      end

      # A retry re-enters the mailbox, which refuses work the runtime cannot
      # accept: an actor class that no longer exists, a full mailbox, a payload
      # over the cap. The operator who pressed the button is told which,
      # instead of being handed a bare 500 from the Rack handler.
      post "/dead_letters/:id/retry", policy: { action: "retry", resource: "dead_letters" } do
        SolidObjects.dead_letters.retry(route_params(:id).to_i, authorization_context: self)
        redirect("/dead_letters")
      rescue Unauthorized
        raise
      rescue SolidObjects::Error => error
        @dead_letter = DeadLetter.find_by(id: route_params(:id))
        halt(404) unless @dead_letter
        @error = "#{error.class.name.split("::").last}: #{error.message}"
        status(422)
        erb(:dead_letter)
      end

      get "/processes", policy: { action: "index", resource: "processes" } do
        @status = filter_value(Statistics::PROCESS_STATES)
        relation = Process.order(last_heartbeat_at: :desc)
        @paginator = paginate(@status ? relation.where(shutdown_state: @status) : relation)
        # Counted in one grouped query rather than once per row, because this
        # page is read while the runtime is already under load.
        @activated_counts = Instance
          .where(activation_owner_id: @paginator.records.map(&:id))
          .group(:activation_owner_id)
          .count
        erb(:processes)
      end

      # @rbs (Hash[String, untyped]) -> Array[untyped]
      def call(env)
        route = self.class.match(env["REQUEST_METHOD"].to_s, env["PATH_INFO"].to_s)
        return not_found unless route

        action = Action.new(env:, route:)
        return forbidden unless authorized?(action)

        respond(action, catch(:halt) { action.call })
      rescue Unauthorized
        forbidden
      end

      private

      # @rbs (Action, untyped) -> Array[untyped]
      def respond(action, result)
        return result if result.is_a?(Array)

        [ action.response_status, page_headers(action.env), [ result.to_s ] ]
      end

      # @rbs (Action) -> bool
      def authorized?(action)
        policy = action.route.policy
        SolidObjects.configuration.authorize_administration.call(
          action: policy.fetch(:action),
          resource: policy.fetch(:resource),
          resource_id: action.route_params(:id),
          authorization_context: action
        )
      end

      # @rbs (Hash[String, untyped]) -> Hash[String, String]
      def page_headers(env)
        {
          "content-type" => "text/html; charset=utf-8",
          "cache-control" => "private, no-store",
          "content-security-policy" => content_security_policy(env),
          "x-content-type-options" => "nosniff",
          "referrer-policy" => "same-origin"
        }
      end

      # The chart host is named only when one is configured, so a deployment
      # that vendors the library or turns charts off never advertises a third
      # party origin it does not use.
      # @rbs (Hash[String, untyped]) -> String
      def content_security_policy(env)
        sources = [ "'self'", "'nonce-#{env[Web::NONCE_KEY]}'", Web.chart_library_origin ].compact
        CONTENT_SECURITY_POLICY.sub(SCRIPT_PLACEHOLDER, sources.join(" "))
      end

      # The cascade header lets a host application serve its own 404 for a path
      # below the mount that the dashboard does not define.
      # @rbs () -> Array[untyped]
      def not_found
        [ 404, { "content-type" => "text/plain", "x-cascade" => "pass" }, [ "Not Found" ] ]
      end

      # @rbs () -> Array[untyped]
      def forbidden
        [ 403, { "content-type" => "text/plain" }, [ "Forbidden" ] ]
      end
    end
  end
end
