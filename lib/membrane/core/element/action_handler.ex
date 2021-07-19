defmodule Membrane.Core.Element.ActionHandler do
  @moduledoc false

  # Module validating and executing actions returned by element's callbacks.

  use Bunch
  use Membrane.Core.CallbackHandler

  import Membrane.Pad, only: [is_pad_ref: 1]

  alias Membrane.{ActionError, Buffer, Caps, CallbackError, Event, Notification, Pad}
  alias Membrane.Core.Element.{DemandHandler, LifecycleController, State}
  alias Membrane.Core.{Events, Message, PlaybackHandler, TimerController}
  alias Membrane.Core.Child.PadModel
  alias Membrane.Core.Telemetry
  alias Membrane.Core.Element.{DemandHandler, LifecycleController, State}
  alias Membrane.Element.Action

  require Membrane.Logger
  require Membrane.Core.Child.PadModel
  require Membrane.Core.Message

  @impl CallbackHandler
  def handle_action(action, callback, params, state) do
    with {:ok, state} <- do_handle_action(action, callback, params, state) do
      {:ok, state}
    else
      {{:error, reason}, state} ->
        raise ActionError, reason: reason, action: action, callback: {state.module, callback}
    end
  end

  defguardp is_demand_size(size) when is_integer(size) or is_function(size)

  @spec do_handle_action(Action.t(), callback :: atom, params :: map, State.t()) ::
          State.stateful_try_t()
  defp do_handle_action({action, _}, :handle_init, _params, state)
       when action not in [:latency] do
    {{:error, :invalid_action}, state}
  end

  defp do_handle_action({action, _}, cb, _params, %State{playback: %{state: :stopped}} = state)
       when action in [:buffer, :event, :caps, :demand, :redemand, :forward, :end_of_stream] and
              cb != :handle_stopped_to_prepared do
    {{:error, {:playback_state, :stopped}}, state}
  end

  defp do_handle_action({:event, {pad_ref, event}}, _cb, _params, state)
       when is_pad_ref(pad_ref) do
    send_event(pad_ref, event, state)
  end

  defp do_handle_action({:notify, notification}, _cb, _params, state),
    do: send_notification(notification, state)

  defp do_handle_action({:split, {callback, args_list}}, cb, params, state) do
    CallbackHandler.exec_and_handle_splitted_callback(
      callback,
      cb,
      __MODULE__,
      params |> Map.merge(%{skip_invoking_redemands: true}),
      args_list,
      state
    )
  end

  defp do_handle_action({:playback_change, :suspend}, cb, _params, state)
       when cb in [
              :handle_stopped_to_prepared,
              :handle_playing_to_prepared,
              :handle_prepared_to_playing,
              :handle_prepared_to_stopped
            ] do
    PlaybackHandler.suspend_playback_change(state)
  end

  defp do_handle_action({:playback_change, :resume}, _cb, _params, state),
    do: PlaybackHandler.continue_playback_change(LifecycleController, state)

  defp do_handle_action({:buffer, {pad_ref, buffers}}, cb, _params, %State{type: type} = state)
       when type in [:source, :filter] and is_pad_ref(pad_ref) do
    send_buffer(pad_ref, buffers, cb, state)
  end

  defp do_handle_action({:caps, {pad_ref, caps}}, _cb, _params, %State{type: type} = state)
       when type in [:source, :filter] and is_pad_ref(pad_ref) do
    send_caps(pad_ref, caps, state)
  end

  defp do_handle_action({:redemand, out_refs}, cb, params, state)
       when is_list(out_refs) do
    out_refs
    |> Bunch.Enum.try_reduce(state, fn out_ref, state ->
      do_handle_action({:redemand, out_ref}, cb, params, state)
    end)
  end

  defp do_handle_action({:redemand, out_ref}, cb, _params, %State{type: type} = state)
       when type in [:source, :filter] and is_pad_ref(out_ref) and
              {type, cb} != {:filter, :handle_demand} do
    handle_redemand(out_ref, state)
  end

  defp do_handle_action({:forward, data}, cb, params, %State{type: :filter} = state)
       when cb in [
              :handle_caps,
              :handle_event,
              :handle_process_list,
              :handle_end_of_stream
            ] do
    dir =
      case cb do
        :handle_event -> Pad.opposite_direction(params.direction)
        _other -> :output
      end

    pads = state |> PadModel.filter_data(%{direction: dir}) |> Map.keys()

    pads
    |> Bunch.Enum.try_reduce(state, fn pad, st ->
      action =
        case cb do
          :handle_event -> {:event, {pad, data}}
          :handle_process_list -> {:buffer, {pad, data}}
          :handle_caps -> {:caps, {pad, data}}
          :handle_end_of_stream -> {:end_of_stream, pad}
        end

      do_handle_action(action, cb, params, st)
    end)
  end

  defp do_handle_action(
         {:demand, pad_ref},
         cb,
         params,
         %State{type: type} = state
       )
       when is_pad_ref(pad_ref) and type in [:sink, :filter] do
    do_handle_action({:demand, {pad_ref, 1}}, cb, params, state)
  end

  defp do_handle_action(
         {:demand, {pad_ref, size}},
         cb,
         _params,
         %State{type: type} = state
       )
       when is_pad_ref(pad_ref) and is_demand_size(size) and type in [:sink, :filter] do
    supply_demand(pad_ref, size, cb, state)
  end

  defp do_handle_action({:start_timer, {id, interval, clock}}, _cb, _params, state) do
    TimerController.start_timer(id, interval, clock, state)
  end

  defp do_handle_action({:start_timer, {id, interval}}, cb, params, state) do
    clock = state.synchronization.parent_clock
    do_handle_action({:start_timer, {id, interval, clock}}, cb, params, state)
  end

  defp do_handle_action({:timer_interval, {id, interval}}, cb, _params, state)
       when interval != :no_interval or cb == :handle_tick do
    TimerController.timer_interval(id, interval, state)
  end

  defp do_handle_action({:stop_timer, id}, _cb, _params, state) do
    TimerController.stop_timer(id, state)
  end

  defp do_handle_action({:latency, latency}, _cb, _params, state) do
    new_state = put_in(state.synchronization.latency, latency)
    {:ok, new_state}
  end

  defp do_handle_action(
         {:end_of_stream, pad_ref},
         _callback,
         _params,
         %State{type: type, playback: %{state: :playing}} = state
       )
       when is_pad_ref(pad_ref) and type != :sink do
    send_event(pad_ref, %Events.EndOfStream{}, state)
  end

  defp do_handle_action(action, callback, _params, state) do
    raise CallbackError, kind: :invalid_action, action: action, callback: {state.module, callback}
  end

  @impl CallbackHandler
  def handle_actions(actions, callback, handler_params, state) do
    {redemands, actions_after_redemands} =
      actions
      |> Enum.drop_while(fn
        {:redemand, _} -> false
        _other_action -> true
      end)
      |> Enum.split_while(fn
        {:redemand, _} -> true
        _other_action -> false
      end)

    case {redemands, actions_after_redemands} do
      {_, []} ->
        super(actions |> join_buffers(), callback, handler_params, state)

      {[redemand | _], _} ->
        raise ActionError,
          reason: :actions_after_redemand,
          action: redemand,
          callback: {state.module, callback}
    end
  end

  defp join_buffers(actions) do
    actions
    |> Bunch.Enum.chunk_by_prev(
      fn
        {:buffer, {pad, _}}, {:buffer, {pad, _}} -> true
        _prev_action, _action -> false
      end,
      fn
        [{:buffer, {pad, _}} | _] = buffers ->
          {:buffer, {pad, buffers |> Enum.map(fn {_, {_, b}} -> [b] end) |> List.flatten()}}

        [other] ->
          other
      end
    )
  end

  @spec send_buffer(Pad.ref_t(), [Buffer.t()] | Buffer.t(), callback :: atom, State.t()) ::
          State.stateful_try_t()
  defp send_buffer(
         _pad_ref,
         _buffer,
         callback,
         %State{playback: %{state: playback_state}} = state
       )
       when playback_state != :playing and callback != :handle_prepared_to_playing do
    {{:error, {:playback_state, playback_state}}, state}
  end

  defp send_buffer(_pad_ref, [], _callback, state) do
    {:ok, state}
  end

  defp send_buffer(pad_ref, %Buffer{} = buffer, callback, state) do
    send_buffer(pad_ref, [buffer], callback, state)
  end

  defp send_buffer(pad_ref, buffers, _callback, state) when is_list(buffers) do
    Membrane.Logger.debug_verbose(
      "Sending #{length(buffers)} buffer(s) through pad #{inspect(pad_ref)}"
    )

    Telemetry.report_metric(:buffer, length(buffers))
    Telemetry.report_bitrate(buffers)

    withl buffers:
            :ok <-
              Bunch.Enum.try_each(buffers, fn
                %Buffer{} -> :ok
                value -> {:error, value}
              end),
          data: {:ok, pad_data} <- PadModel.get_data(state, pad_ref),
          dir: %{direction: :output} <- pad_data,
          eos: %{end_of_stream?: false} <- pad_data do
      %{mode: mode, pid: pid, other_ref: other_ref, other_demand_unit: other_demand_unit} =
        pad_data

      state = handle_buffer(pad_ref, mode, other_demand_unit, buffers, state)
      Message.send(pid, :buffer, buffers, for_pad: other_ref)
      {:ok, state}
    else
      buffers: {:error, buf} -> {{:error, {:invalid_buffer, buf}}, state}
      data: {:error, reason} -> {{:error, reason}, state}
      dir: %{direction: dir} -> {{:error, {:invalid_pad_dir, dir}}, state}
      eos: %{end_of_stream?: true} -> {{:error, {:eos_sent, pad_ref}}, state}
    end
  end

  defp send_buffer(_pad_ref, invalid_value, _callback, state) do
    {{:error, {:invalid_buffer, invalid_value}}, state}
  end

  @spec handle_buffer(
          Pad.ref_t(),
          Pad.mode_t(),
          Buffer.Metric.unit_t(),
          [Buffer.t()],
          State.t()
        ) :: State.t()
  defp handle_buffer(pad_ref, :pull, other_demand_unit, buffers, state) do
    buf_size = Buffer.Metric.from_unit(other_demand_unit).buffers_size(buffers)

    state
    |> PadModel.update_data!(pad_ref, :demand, &(&1 - buf_size))
    |> PadModel.set_data!(pad_ref, :start_of_stream?, true)
  end

  defp handle_buffer(_pad_ref, :push, _options, _buffers, state) do
    state
  end

  @spec send_caps(Pad.ref_t(), Caps.t(), State.t()) :: State.stateful_try_t()
  def send_caps(pad_ref, caps, state) do
    Membrane.Logger.debug("""
    Sending caps through pad #{inspect(pad_ref)}
    Caps: #{inspect(caps)}
    """)

    withl pad: {:ok, pad_data} <- PadModel.get_data(state, pad_ref),
          direction: %{direction: :output} <- pad_data,
          caps: true <- Caps.Matcher.match?(pad_data.accepted_caps, caps) do
      %{pid: pid, other_ref: other_ref} = pad_data

      state = state |> PadModel.set_data!(pad_ref, :caps, caps)

      Message.send(pid, :caps, caps, for_pad: other_ref)
      {:ok, state}
    else
      pad: {:error, reason} -> {{:error, reason}, state}
      direction: %{direction: dir} -> {{:error, {:invalid_pad_dir, pad_ref, dir}}, state}
      caps: false -> {{:error, {:invalid_caps, caps, pad_data.accepted_caps}}, state}
    end
  end

  @spec supply_demand(
          Pad.ref_t(),
          Action.demand_size_t(),
          callback :: atom,
          State.t()
        ) :: State.stateful_try_t()

  defp supply_demand(
         _pad_ref,
         _size,
         callback,
         %State{playback: %{state: playback_state}} = state
       )
       when playback_state != :playing and callback != :handle_prepared_to_playing do
    {{:error, {:playback_state, playback_state}}, state}
  end

  defp supply_demand(pad_ref, 0, callback, state) do
    Membrane.Logger.debug_verbose("""
    Ignoring demand of size of 0 requested by callback #{inspect(callback)}
    on pad #{inspect(pad_ref)}.
    """)

    {:ok, state}
  end

  defp supply_demand(_pad_ref, size, _callback, state)
       when is_integer(size) and size < 0 do
    {{:error, :negative_demand}, state}
  end

  defp supply_demand(pad_ref, size, _callback, state) do
    withl data: {:ok, pad_data} <- PadModel.get_data(state, pad_ref),
          dir: %{direction: :input} <- pad_data,
          mode: %{mode: :pull} <- pad_data,
          update: {:ok, state} <- DemandHandler.update_demand(pad_ref, size, state) do
      DemandHandler.supply_demand(pad_ref, state)
    else
      data: {:error, reason} -> {{:error, reason}, state}
      dir: %{direction: dir} -> {{:error, {:invalid_pad_dir, pad_ref, dir}}, state}
      mode: %{mode: mode} -> {{:error, {:invalid_pad_mode, pad_ref, mode}}, state}
      update: {{:error, reason}, state} -> {{:error, reason}, state}
    end
  end

  @spec handle_redemand(Pad.ref_t(), State.t()) :: State.stateful_try_t()
  defp handle_redemand(out_ref, %{type: type} = state) when type in [:source, :filter] do
    withl data: {:ok, pad_data} <- PadModel.get_data(state, out_ref),
          dir: %{direction: :output} <- pad_data,
          mode: %{mode: :pull} <- pad_data do
      DemandHandler.handle_redemand(out_ref, state)
    else
      data: {:error, reason} -> {{:error, reason}, state}
      dir: %{direction: dir} -> {{:error, {:invalid_pad_dir, out_ref, dir}}, state}
      mode: %{mode: mode} -> {{:error, {:invalid_pad_mode, out_ref, mode}}, state}
    end
  end

  @spec send_event(Pad.ref_t(), Event.t(), State.t()) :: State.stateful_try_t()
  defp send_event(pad_ref, event, state) do
    Membrane.Logger.debug_verbose("""
    Sending event through pad #{inspect(pad_ref)}
    Event: #{inspect(event)}
    """)

    withl event: true <- event |> Event.event?(),
          pad: {:ok, %{pid: pid, other_ref: other_ref}} <- PadModel.get_data(state, pad_ref),
          handler: {:ok, state} <- handle_event(pad_ref, event, state) do
      Message.send(pid, :event, event, for_pad: other_ref)
      {:ok, state}
    else
      event: false -> {{:error, {:invalid_event, event}}, state}
      pad: {:error, reason} -> {{:error, reason}, state}
      handler: {{:error, reason}, state} -> {{:error, reason}, state}
    end
  end

  @spec handle_event(Pad.ref_t(), Event.t(), State.t()) :: State.stateful_try_t()
  defp handle_event(pad_ref, %Events.EndOfStream{}, state) do
    with %{direction: :output, end_of_stream?: false} <- PadModel.get_data!(state, pad_ref) do
      {:ok, PadModel.set_data!(state, pad_ref, :end_of_stream?, true)}
    else
      %{direction: :input} ->
        {{:error, {:invalid_pad_dir, pad_ref, :input}}, state}

      %{end_of_stream?: true} ->
        {{:error, {:eos_sent, pad_ref}}, state}
    end
  end

  defp handle_event(_pad_ref, _event, state), do: {:ok, state}

  @spec send_notification(Notification.t(), State.t()) :: {:ok, State.t()}
  defp send_notification(notification, %State{watcher: nil} = state) do
    Membrane.Logger.debug_verbose(
      "Dropping notification #{inspect(notification)} as watcher is undefined"
    )

    {:ok, state}
  end

  defp send_notification(notification, %State{watcher: watcher, name: name} = state) do
    Membrane.Logger.debug_verbose(
      "Sending notification #{inspect(notification)} (watcher: #{inspect(watcher)})"
    )

    Message.send(watcher, :notification, [name, notification])
    {:ok, state}
  end
end
