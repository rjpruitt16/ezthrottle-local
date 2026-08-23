import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ezthrottle_local start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ezthrottle_local, EzthrottleLocalWeb.Endpoint, server: true
end

# default_rps was already read via Application.get_env in url_actor.ex but
# had no env var wired to it anywhere -- every UrlActor silently used the
# 2.0 fallback regardless of deployment. Wired here the same way
# MNESIA_DIR/EZTHROTTLE_MEMORY_LIMIT_MB already are.
if rps = System.get_env("EZTHROTTLE_DEFAULT_RPS") do
  case Float.parse(rps) do
    {value, _} -> config :ezthrottle_local, default_rps: value
    :error -> :ok
  end
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ezthrottle_local, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :ezthrottle_local, :mnesia_dir, System.get_env("MNESIA_DIR", "/data/mnesia")

  config :ezthrottle_local, EzthrottleLocalWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # IPv4 any-address, not IPv6 — fly-proxy's own health/process
      # scanning explicitly checks for a raw 0.0.0.0:PORT listener and
      # flagged this app as unreachable when it was bound to :::PORT
      # (IPv6-any) instead, even though ad-hoc curl requests still worked
      # by luck of dual-stack routing. This app doesn't need IPv6 client
      # support, so bind plainly on IPv4 to match what Fly's tooling
      # actually checks for.
      ip: {0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ezthrottle_local, EzthrottleLocalWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ezthrottle_local, EzthrottleLocalWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
