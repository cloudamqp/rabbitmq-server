%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(sync_detection_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-compile(export_all).

-define(LOOP_RECURSION_DELAY, 100).

all() ->
    [
      {group, cluster_size_2},
      {group, cluster_size_3}
    ].

groups() ->
    [
      {cluster_size_2, [], [
          slave_synchronization,
          slave_synchronization_strict_promotion_false,
	  slave_synchronization_strict_promotion_true
        ]},
      {cluster_size_3, [], [
          slave_synchronization_ttl
        ]}
    ].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(cluster_size_2, Config) ->
    rabbit_ct_helpers:set_config(Config, [{rmq_nodes_count, 2}]);
init_per_group(cluster_size_3, Config) ->
    rabbit_ct_helpers:set_config(Config, [{rmq_nodes_count, 3}]).

end_per_group(_, Config) ->
    Config.

init_per_testcase(Testcase = slave_synchronization_strict_promotion_true, Config) ->
    common_setup(Testcase, Config, [{promote_only_sync_slaves, true}]);
init_per_testcase(Testcase, Config) ->
    common_setup(Testcase, Config, []).

common_setup(Testcase, Config, EnvVariables) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase),
    ClusterSize = ?config(rmq_nodes_count, Config),
    TestNumber = rabbit_ct_helpers:testcase_number(Config, ?MODULE, Testcase),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodes_count, ClusterSize},
        {rmq_nodes_clustered, true},
        {rmq_nodename_suffix, Testcase},
        {tcp_ports_base, {skip_n_nodes, TestNumber * ClusterSize}}
      ]),
    Config2 = rabbit_ct_helpers:merge_app_env(Config1, {rabbit, EnvVariables}),
    rabbit_ct_helpers:run_steps(Config2,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps() ++ [
        fun rabbit_ct_broker_helpers:set_ha_policy_two_pos/1,
        fun rabbit_ct_broker_helpers:set_ha_policy_two_pos_batch_sync/1
						]).

end_per_testcase(Testcase, Config) ->
    Config1 = rabbit_ct_helpers:run_steps(Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()),
    rabbit_ct_helpers:testcase_finished(Config1, Testcase).

%% -------------------------------------------------------------------
%% Testcases.
%% -------------------------------------------------------------------

slave_synchronization(Config) ->
    [Master, Slave] = rabbit_ct_broker_helpers:get_node_configs(Config,
      nodename),
    Channel = rabbit_ct_client_helpers:open_channel(Config, Master),
    Queue = <<"ha.two.test">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = Queue,
                                                    auto_delete = false}),

    %% The comments on the right are the queue length and the pending acks on
    %% the master.
    rabbit_ct_broker_helpers:stop_broker(Config, Slave),

    %% We get and ack one message when the slave is down, and check that when we
    %% start the slave it's not marked as synced until ack the message.  We also
    %% publish another message when the slave is up.
    send_dummy_message(Channel, Queue),                                 % 1 - 0
    {#'basic.get_ok'{delivery_tag = Tag1}, _} =
        amqp_channel:call(Channel, #'basic.get'{queue = Queue}),        % 0 - 1

    rabbit_ct_broker_helpers:start_broker(Config, Slave),

    slave_unsynced(Master, Queue),
    send_dummy_message(Channel, Queue),                                 % 1 - 1
    slave_unsynced(Master, Queue),

    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag1}),      % 1 - 0

    slave_synced(Master, Queue),

    %% We restart the slave and we send a message, so that the slave will only
    %% have one of the messages.
    rabbit_ct_broker_helpers:stop_broker(Config, Slave),
    rabbit_ct_broker_helpers:start_broker(Config, Slave),

    send_dummy_message(Channel, Queue),                                 % 2 - 0

    slave_unsynced(Master, Queue),

    %% We reject the message that the slave doesn't have, and verify that it's
    %% still unsynced
    {#'basic.get_ok'{delivery_tag = Tag2}, _} =
        amqp_channel:call(Channel, #'basic.get'{queue = Queue}),        % 1 - 1
    slave_unsynced(Master, Queue),
    amqp_channel:cast(Channel, #'basic.reject'{ delivery_tag = Tag2,
                                                requeue      = true }), % 2 - 0
    slave_unsynced(Master, Queue),
    {#'basic.get_ok'{delivery_tag = Tag3}, _} =
        amqp_channel:call(Channel, #'basic.get'{queue = Queue}),        % 1 - 1
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag3}),      % 1 - 0
    slave_synced(Master, Queue),
    {#'basic.get_ok'{delivery_tag = Tag4}, _} =
        amqp_channel:call(Channel, #'basic.get'{queue = Queue}),        % 0 - 1
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag4}),      % 0 - 0
    slave_synced(Master, Queue).

slave_synchronization_ttl(Config) ->
    [Master, Slave, DLX] = rabbit_ct_broker_helpers:get_node_configs(Config,
      nodename),
    Channel = rabbit_ct_client_helpers:open_channel(Config, Master),
    DLXChannel = rabbit_ct_client_helpers:open_channel(Config, DLX),

    %% We declare a DLX queue to wait for messages to be TTL'ed
    DLXQueue = <<"dlx-queue">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = DLXQueue,
                                                    auto_delete = false}),

    TestMsgTTL = 5000,
    Queue = <<"ha.two.test">>,
    %% Sadly we need fairly high numbers for the TTL because starting/stopping
    %% nodes takes a fair amount of time.
    Args = [{<<"x-message-ttl">>, long, TestMsgTTL},
            {<<"x-dead-letter-exchange">>, longstr, <<>>},
            {<<"x-dead-letter-routing-key">>, longstr, DLXQueue}],
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = Queue,
                                                    auto_delete = false,
                                                    arguments   = Args}),

    slave_synced(Master, Queue),

    %% All unknown
    rabbit_ct_broker_helpers:stop_broker(Config, Slave),
    send_dummy_message(Channel, Queue),
    send_dummy_message(Channel, Queue),
    rabbit_ct_broker_helpers:start_broker(Config, Slave),
    slave_unsynced(Master, Queue),
    wait_for_messages(DLXQueue, DLXChannel, 2),
    slave_synced(Master, Queue),

    %% 1 unknown, 1 known
    rabbit_ct_broker_helpers:stop_broker(Config, Slave),
    send_dummy_message(Channel, Queue),
    rabbit_ct_broker_helpers:start_broker(Config, Slave),
    slave_unsynced(Master, Queue),
    send_dummy_message(Channel, Queue),
    slave_unsynced(Master, Queue),
    wait_for_messages(DLXQueue, DLXChannel, 2),
    slave_synced(Master, Queue),

    %% %% both known
    send_dummy_message(Channel, Queue),
    send_dummy_message(Channel, Queue),
    slave_synced(Master, Queue),
    wait_for_messages(DLXQueue, DLXChannel, 2),
    slave_synced(Master, Queue),

    ok.

slave_synchronization_strict_promotion_false(Config) ->
    [Master, Mirror] =
        rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    Channel = rabbit_ct_client_helpers:open_channel(Config, Master),
    QueueName = <<"ha.two.test">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = QueueName,
						    auto_delete = false,
						    durable     = true}),

    lists:foreach(fun(_N)-> send_dummy_message(Channel, QueueName) end,
		  lists:seq(1, 10000)),

    ok = rabbit_ct_broker_helpers:stop_broker(Config, Master),

    true = ensure_promotion(Mirror, QueueName),

    ok = rabbit_ct_broker_helpers:start_broker(Config, Master),

    slave_unsynced(Master, QueueName),
    {ok, NewQueueMaster} = rpc:call(Mirror, rabbit_queue_master_location_misc,
				    lookup_master, [QueueName, <<"/">>]),
    NewQueueMaster = Mirror,
    slave_unsynced(NewQueueMaster, QueueName),
    rpc:call(NewQueueMaster, rabbit_amqqueue, sync_mirrors,
	     [get_queue_pid(QueueName, NewQueueMaster)]),
    slave_synced(NewQueueMaster, QueueName).


slave_synchronization_strict_promotion_true(Config) ->
    [Master, Mirror] =
        rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    Channel = rabbit_ct_client_helpers:open_channel(Config, Master),
    QueueName = <<"ha.two.test">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = QueueName,
						    auto_delete = false,
						    durable     = true}),

    send_dummy_message(Channel, QueueName),
    {#'basic.get_ok'{delivery_tag = _Tag1}, _} =
        amqp_channel:call(Channel, #'basic.get'{queue = QueueName}),

    lists:foreach(fun(_N)-> send_dummy_message(Channel, QueueName, 2) end,
		  lists:seq(1, 10000)),

    %% ====== A tweak to enforce the mirror to be out-of-sync with the master. ======
    %% Compile and transfer the test suite code to the mirror node. This is needed
    %% inorder for the fun() inside the following rpc:multicall/4 to be available for
    %% remote execution. Otherwise the rpc:multicall/4 fails.
    {Module, Binary, Filename} = code:get_object_code(?MODULE),
    {[{module, ?MODULE}, {module, ?MODULE}], []} =
	rpc:multicall([Master, Mirror], code, load_binary, [Module, Filename, Binary]),

    %% Enforce both the master and mirror to believe none of the mirror(s)
    %% are in sync with the master.
    {[ok, ok], []} = rpc:multicall([Master, Mirror], rabbit_misc,
				   execute_mnesia_transaction,
				   [fun()->
					    QueueKey = rabbit_misc:r(<<"/">>, queue, QueueName),
					    [QueueRec] = mnesia:read({rabbit_queue, QueueKey}),
					    UpdatedQueueRec = QueueRec#amqqueue{sync_slave_pids = []},
					    mnesia:write(rabbit_queue, UpdatedQueueRec, write),
					    ok
				    end]),
    %% ====== completion of the tweak =================================================

    rabbit_ct_broker_helpers:stop_broker(Config, Master),
    false = ensure_promotion(Mirror, QueueName),
    rabbit_ct_broker_helpers:start_broker(Config, Master),

    slave_unsynced(Master, QueueName),
    true = (get_queue_messages(Master, QueueName) >= get_queue_messages(Mirror, QueueName)),
    false = ensure_promotion(Mirror, QueueName),
    rpc:call(Master, rabbit_amqqueue, sync_mirrors, [get_queue_pid(QueueName, Master)]),
    true = (get_queue_messages(Master, QueueName) =:= get_queue_messages(Mirror, QueueName)),

    slave_synced(Master, QueueName),
    QueueMasterNodeAtMirror = get_queue_master_node(Mirror, QueueName),
    QueueMasterNodeAtMaster = get_queue_master_node(Master, QueueName),
    QueueMasterNodeAtMaster = QueueMasterNodeAtMirror = Master.


%% ======= Internal functions ======================================
get_queue_pid(QueueName, Node) ->
    AllQueues = rpc:call(Node, rabbit_amqqueue, list, []),
    [QueuePid] = lists:foldl(fun(#amqqueue{pid = QPid} = Queue, Acc)->
				     {resource, _, queue, QName} = Queue#amqqueue.name,
				     case QName =:= QueueName of
					 true -> [QPid | Acc];
					 false -> Acc
				     end
			     end,
			     [], AllQueues),
    QueuePid.

ensure_promotion(Node, QueueName) ->
    lists:foldl(fun(_N, _Acc)->
			timer:sleep(?LOOP_RECURSION_DELAY),
			QueueMasterNode = get_queue_master_node(Node, QueueName),
			QueueMasterNode =:= Node
		end,
		false, lists:seq(1, 50)).

get_queue_master_node(Node, QueueName) ->
    {ok, QueueMasterNode} = rpc:call(Node, rabbit_queue_master_location_misc,
				     lookup_master, [QueueName, <<"/">>]),
    QueueMasterNode.

send_dummy_message(Channel, QueueName) ->
    Payload = <<"foo">>,
    Publish = #'basic.publish'{exchange = <<>>, routing_key = QueueName},
    amqp_channel:cast(Channel, Publish, #amqp_msg{payload = Payload}).
send_dummy_message(Channel, QueueName, Mode) ->
    Payload = <<"foo">>,
    Publish = #'basic.publish'{exchange = <<>>, routing_key = QueueName},
    amqp_channel:cast(Channel, Publish, #amqp_msg{payload = Payload,
						  props = #'P_basic'
						  {delivery_mode=Mode}}).

slave_synced(Node, QueueName) ->
    wait_for_sync_status(true, Node, QueueName).

slave_unsynced(Node, QueueName) ->
    wait_for_sync_status(false, Node, QueueName).

%% The mnesia synchronization takes a while, but we don't want to wait for the
%% test to fail, since the timetrap is quite high.
wait_for_sync_status(Status, Node, QueueName) ->
    Max = 10000 / ?LOOP_RECURSION_DELAY,
    wait_for_sync_status(0, Max, Status, Node, QueueName).

wait_for_sync_status(N, Max, Status, Node, QueueName) when N >= Max ->
    erlang:error({sync_status_max_tries_failed,
                  [{queue, QueueName},
                   {node, Node},
                   {expected_status, Status},
                   {max_tried, Max}]});
wait_for_sync_status(N, Max, Status, Node, QueueName) ->
    SyncedSlavePids = synchronised_slave_pids(Node, QueueName),
    Synced = length(SyncedSlavePids) =:= 1,
    case Synced =:= Status of
        true  -> ok;
        false -> timer:sleep(?LOOP_RECURSION_DELAY),
                 wait_for_sync_status(N + 1, Max, Status, Node, QueueName)
    end.

synchronised_slave_pids(Node, QueueName) ->
    {ok, Queue} = rpc:call(Node, rabbit_amqqueue, lookup,
                       [rabbit_misc:r(<<"/">>, queue, QueueName)]),
    SSP = synchronised_slave_pids,
    [{SSP, Pids}] = rpc:call(Node, rabbit_amqqueue, info, [Queue, [SSP]]),
    case Pids of
        '' -> [];
        _  -> Pids
    end.

wait_for_messages(Queue, Channel, N) ->
    Sub = #'basic.consume'{queue = Queue},
    #'basic.consume_ok'{consumer_tag = CTag} = amqp_channel:call(Channel, Sub),
    receive
        #'basic.consume_ok'{} -> ok
    end,
    lists:foreach(
      fun (_) -> receive
                     {#'basic.deliver'{delivery_tag = Tag}, _Content} ->
                         amqp_channel:cast(Channel,
                                           #'basic.ack'{delivery_tag = Tag})
                 end
      end, lists:seq(1, N)),
    amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = CTag}).

slave_pids(Node, QueueName) ->
    {ok, Queue} = rpc:call(Node, rabbit_amqqueue, lookup,
                       [rabbit_misc:r(<<"/">>, queue, QueueName)]),
    SSP = slave_pids,
    [{SSP, Pids}] = rpc:call(Node, rabbit_amqqueue, info, [Queue, [SSP]]),
    case Pids of
        '' -> [];
        _  -> Pids
    end.

get_queue_messages(Node, QueueName) ->
    {ok, Queue} = rpc:call(Node, rabbit_amqqueue, lookup,
                       [rabbit_misc:r(<<"/">>, queue, QueueName)]),
    [{messages, Messages}] = rpc:call(Node, rabbit_amqqueue, info, [Queue, [messages]]),
    Messages.
