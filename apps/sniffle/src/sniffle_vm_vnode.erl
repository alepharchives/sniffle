-module(sniffle_vm_vnode).
-behaviour(riak_core_vnode).
-include("sniffle.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([repair/3,
	 get/3,
	 list/2,
	 list/3,
	 register/4,
	 unregister/3,
	 set_attribute/4
	]).

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-record(state, {
	  vms,
	  partition,
	  node
	 }).

% those functions do not get called directly.
-ignore_xref([
	      get/3,
	      list/2,
	      list/3,
	      register/4,
	      repair/3,
	      set_attribute/4,
	      start_vnode/1,
	      unregister/3
	      ]).


-define(MASTER, sniffle_vm_vnode_master).

%%%===================================================================
%%% API
%%%===================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

repair(IdxNode, Vm, Obj) ->
    riak_core_vnode_master:command(IdxNode,
                                   {repair, Vm, Obj},
                                   ignore,
                                   ?MASTER).

%%%===================================================================
%%% API - reads
%%%===================================================================

-spec get(any(), any(), Vm::fifo:uuid()) -> ok.

get(Preflist, ReqID, Vm) ->
    ?PRINT({get, Preflist, ReqID, Vm}),
    riak_core_vnode_master:command(Preflist,
				   {get, ReqID, Vm},
				   {fsm, undefined, self()},
				   ?MASTER).

%%%===================================================================
%%% API - coverage
%%%===================================================================

-spec list(any(), any()) -> ok.

list(Preflist, ReqID) ->
    riak_core_vnode_master:coverage(
      {list, ReqID},
      Preflist,
      all,
      {fsm, undefined, self()},
      ?MASTER).

-spec list(any(), any(), [fifo:matcher()]) -> ok.

list(Preflist, ReqID, Requirements) ->
    riak_core_vnode_master:coverage(
      {list, ReqID, Requirements},
      Preflist,
      all,
      {fsm, undefined, self()},
      ?MASTER).

%%%===================================================================
%%% API - writes
%%%===================================================================

-spec register(any(), any(), fifo:uuid(), binary()) -> ok.

register(Preflist, ReqID, Vm, Hypervisor) ->
    riak_core_vnode_master:command(Preflist,
				   {register, ReqID, Vm, Hypervisor},
				   {fsm, undefined, self()},
				   ?MASTER).

-spec unregister(any(), any(), fifo:uuid()) -> ok.

unregister(Preflist, ReqID, Vm) ->
    riak_core_vnode_master:command(Preflist,
                                   {unregister, ReqID, Vm},
				   {fsm, undefined, self()},
                                   ?MASTER).


-spec set_attribute(any(), any(), fifo:uuid(), [{Key::binary(), V::fifo:value()}]) -> ok.

set_attribute(Preflist, ReqID, Vm, Data) ->
    riak_core_vnode_master:command(Preflist,
                                   {attribute, set, ReqID, Vm, Data},
				   {fsm, undefined, self()},
                                   ?MASTER).

%%%===================================================================
%%% VNode
%%%===================================================================

init([Partition]) ->
    {ok, #state{
       vms = dict:new(),
       partition = Partition,
       node = node()
      }}.

-type vm_command() ::
	ping |
	{repair, Vm::fifo:uuid(), Obj::any()} |
	{get, ReqID::any(), Vm::fifo:uuid()} |
	{get, ReqID::any(), Vm::fifo:uuid()} |
	{register, {ReqID::any(), Coordinator::any()}, Vm::fifo:uuid(), Hypervisor::binary()} |
	{unregister, {ReqID::any(), _Coordinator::any()}, Vm::fifo:uuid()} |
	{attribute, set,
	 {ReqID::any(), Coordinator::any()}, Vm::fifo:uuid(),
	 Resources::[{Key::binary(), Value::fifo:value()}]}.

-spec handle_command(vm_command(), any(), any()) ->
			    {reply, any(), any()} |
			    {noreply, any()}.

handle_command(ping, _Sender, State) ->
    {reply, {pong, State#state.partition}, State};

handle_command({repair, Vm, Obj}, _Sender, State) ->
    Hs0 = dict:store(Vm, Obj, State#state.vms),
    {noreply, State#state{vms=Hs0}};

handle_command({get, ReqID, Vm}, _Sender, State) ->
    ?PRINT({handle_command, get, ReqID, Vm}),
    NodeIdx = {State#state.partition, State#state.node},
    Res = case dict:find(Vm, State#state.vms) of
	      error ->
		  {ok, ReqID, NodeIdx, not_found};
	      {ok, V} ->
		  {ok, ReqID, NodeIdx, V}
	  end,
    {reply,
     Res,
     State};

handle_command({register, {ReqID, Coordinator}, Vm, Hypervisor}, _Sender, State) ->
    H0 = statebox:new(fun sniffle_vm_state:new/0),
    H1 = statebox:modify({fun sniffle_vm_state:uuid/2, [Vm]}, H0),
    H2 = statebox:modify({fun sniffle_vm_state:hypervisor/2, [Hypervisor]}, H1),

    VC0 = vclock:fresh(),
    VC = vclock:increment(Coordinator, VC0),
    HObject = #sniffle_obj{val=H2, vclock=VC},

    Hs0 = dict:store(Vm, HObject, State#state.vms),
    {reply, {ok, ReqID}, State#state{vms = Hs0}};

handle_command({unregister, {ReqID, _Coordinator}, Vm}, _Sender, State) ->
    Hs0 = dict:erase(Vm, State#state.vms),
    {reply, {ok, ReqID}, State#state{vms = Hs0}};

handle_command({attribute, set,
		{ReqID, Coordinator}, Vm,
		Resources}, _Sender, State) ->
    Hs0 = dict:update(Vm,
		      fun(#sniffle_obj{val=H0} = O) ->
			      H1 = lists:foldr(
				     fun ({Resource, Value}, H) ->
					     statebox:modify(
					       {fun sniffle_vm_state:attribute/3,
						[Resource, Value]}, H)
				     end, H0, Resources),
			      H2 = statebox:expire(?STATEBOX_EXPIRE, H1),
			      sniffle_obj:update(H2, Coordinator, O)
		      end, State#state.vms),
    {reply, {ok, ReqID}, State#state{vms = Hs0}};

handle_command(Message, _Sender, State) ->
    ?PRINT({unhandled_command, Message}),
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, _Sender, State) ->
    Acc = dict:fold(Fun, Acc0, State#state.vms),
    {reply, Acc, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, State) ->
    {Vm, HObject} = binary_to_term(Data),
    Hs0 = dict:store(Vm, HObject, State#state.vms),
    {reply, ok, State#state{vms = Hs0}}.

encode_handoff_item(Vm, Data) ->
    term_to_binary({Vm, Data}).

is_empty(State) ->
    case dict:size(State#state.vms) of
	0 ->
	    {true, State};
	_ ->
	    {true, State}
    end.

delete(State) ->
    {ok, State#state{vms = dict:new()}}.

handle_coverage({list, ReqID}, _KeySpaces, _Sender, State) ->
    {reply,
     {ok, ReqID, {State#state.partition,State#state.node}, dict:fetch_keys(State#state.vms)},
     State};

handle_coverage({list, ReqID, Requirements}, _KeySpaces, _Sender, State) ->
    Getter = fun(#sniffle_obj{val=S0}, <<"uuid">>) ->
		     Vm = statebox:value(S0),
		     Vm#vm.uuid;
		(#sniffle_obj{val=S0}, <<"hypervisor">>) ->
		     Vm = statebox:value(S0),
		     Vm#vm.hypervisor;
		(#sniffle_obj{val=S0}, Resource) ->
		     Vm = statebox:value(S0),
		     dict:fetch(Resource, Vm#vm.attributes)
	     end,
    Server = sniffle_matcher:match_dict(State#state.vms, Getter, Requirements),
    {reply,
     {ok, ReqID, {State#state.partition, State#state.node}, Server},
     State};


handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
