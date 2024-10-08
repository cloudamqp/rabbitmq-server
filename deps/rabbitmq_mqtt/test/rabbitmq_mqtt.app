{application, rabbitmq_mqtt,
 [{description, "RabbitMQ MQTT Adapter"},
  {vsn, "%%VSN%%"},
  {modules, []},
  {registered, []},
  {mod, {rabbit_mqtt, []}},
  {env, [{ssl_cert_login,false},
         {allow_anonymous, true},
         {vhost, "/"},
         {exchange, "amq.topic"},
         {subscription_ttl, 1800000}, % 30 min
         {prefetch, 10},
         {ssl_listeners, []},
         {tcp_listeners, [1883]},
         {tcp_listen_options, [{backlog,   128},
                               {nodelay,   true}]}]},
  {applications, [kernel, stdlib, rabbit, amqp_client]}]}.
