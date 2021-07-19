defmodule Membrane.Core.Element.EventController do
  @moduledoc false

  # Module handling events incoming through input pads.

  use Bunch

  alias Membrane.{Event, Pad, Sync}
  alias Membrane.Core.{CallbackHandler, Events, InputBuffer, Message, Telemetry}
  alias Membrane.Core.Child.PadModel
  alias Membrane.Core.Element.{ActionHandler, State}
  alias Membrane.Element.CallbackContext

  require Membrane.Core.Child.PadModel
  require Membrane.Core.Message
  require Membrane.Logger

  @spec handle_start_of_stream(Pad.ref_t(), State.t()) :: State.stateful_try_t()
  def handle_start_of_stream(pad_ref, state) do
    handle_event(pad_ref, %Events.StartOfStream{}, state)
  end

  @doc """
  Handles incoming event: either stores it in InputBuffer, or executes element callback.
  Extra checks and tasks required by special events such as `:start_of_stream`
  or `:end_of_stream` are performed.
  """
  @spec handle_event(Pad.ref_t(), Event.t(), State.t()) :: State.stateful_try_t()
  def handle_event(pad_ref, event, state) do
    Telemetry.report_metric(:event, 1, inspect(pad_ref))

    pad_data = PadModel.get_data!(state, pad_ref)

    if not Event.async?(event) && pad_data.mode == :pull && pad_data.direction == :input &&
         buffers_before_event_present?(pad_data) do
      PadModel.update_data(
        state,
        pad_ref,
        :input_buf,
        &{:ok, InputBuffer.store(&1, :event, event)}
      )
    else
      exec_handle_event(pad_ref, event, state)
    end
  end

  @spec exec_handle_event(Pad.ref_t(), Event.t(), params :: map, State.t()) ::
          State.stateful_try_t()
  def exec_handle_event(pad_ref, event, params \\ %{}, state) do
    withl handle: {{:ok, :handle}, state} <- handle_special_event(pad_ref, event, state),
          try: {:ok, state} <- check_sync(event, state),
          try: {:ok, state} <- do_exec_handle_event(pad_ref, event, params, state) do
      {:ok, state}
    else
      handle: {{:ok, :ignore}, state} ->
        Membrane.Logger.debug("Ignoring event #{inspect(event)}")
        {:ok, state}

      handle: {{:error, reason}, state} ->
        Membrane.Logger.error("""
        Error while handling event, reason: #{inspect(reason)}
        State: #{inspect(state, pretty: true)}
        """)

        {{:error, {:handle_event, reason}}, state}

      try: {{:error, reason}, state} ->
        Membrane.Logger.error("""
        Error while handling event, reason: #{inspect(reason)}
        State: #{inspect(state, pretty: true)}
        """)

        {{:error, {:handle_event, reason}}, state}
    end
  end

  @spec do_exec_handle_event(Pad.ref_t(), Event.t(), params :: map, State.t()) ::
          State.stateful_try_t()
  defp do_exec_handle_event(pad_ref, %event_type{} = event, params, state)
       when event_type in [Events.StartOfStream, Events.EndOfStream] do
    data = PadModel.get_data!(state, pad_ref)
    require CallbackContext.StreamManagement
    context = CallbackContext.StreamManagement.from_state(state)

    callback = stream_event_to_callback(event)
    new_params = Map.put(params, :direction, data.direction)
    args = [pad_ref, context]

    res =
      CallbackHandler.exec_and_handle_callback(
        callback,
        ActionHandler,
        new_params,
        args,
        state
      )

    if state.watcher, do: Message.send(state.watcher, callback, [state.name, pad_ref])

    res
  end

  defp do_exec_handle_event(pad_ref, event, params, state) do
    data = PadModel.get_data!(state, pad_ref)
    require CallbackContext.Event
    context = &CallbackContext.Event.from_state/1
    params = %{context: context, direction: data.direction} |> Map.merge(params)
    args = [pad_ref, event]
    CallbackHandler.exec_and_handle_callback(:handle_event, ActionHandler, params, args, state)
  end

  defp check_sync(%Events.StartOfStream{}, state) do
    if state.pads.data
       |> Map.values()
       |> Enum.filter(&(&1.direction == :input))
       |> Enum.all?(& &1.start_of_stream?) do
      :ok = Sync.sync(state.synchronization.stream_sync)
    end

    {:ok, state}
  end

  defp check_sync(_event, state) do
    {:ok, state}
  end

  @spec handle_special_event(Pad.ref_t(), Event.t(), State.t()) ::
          State.stateful_try_t(:handle | :ignore)
  defp handle_special_event(pad_ref, %Events.StartOfStream{}, state) do
    with %{direction: :input, start_of_stream?: false} <- PadModel.get_data!(state, pad_ref) do
      state
      |> PadModel.set_data!(pad_ref, :start_of_stream?, true)
      ~> {{:ok, :handle}, &1}
    else
      %{direction: :output} ->
        {{:error, {:received_start_of_stream_through_output, pad_ref}}, state}

      %{start_of_stream?: true} ->
        {{:error, {:start_of_stream_already_received, pad_ref}}, state}
    end
  end

  defp handle_special_event(pad_ref, %Events.EndOfStream{}, state) do
    pad_data = PadModel.get_data!(state, pad_ref)

    withl data: %{direction: :input, start_of_stream?: true, end_of_stream?: false} <- pad_data,
          playback: %{state: :playing} <- state.playback do
      state
      |> PadModel.set_data!(pad_ref, :end_of_stream?, true)
      ~> {{:ok, :handle}, &1}
    else
      data: %{direction: :output} ->
        {{:error, {:received_end_of_stream_through_output, pad_ref}}, state}

      data: %{end_of_stream?: true} ->
        Membrane.Logger.debug("Ignoring end of stream as it has already come before")
        {{:ok, :ignore}, state}

      data: %{start_of_stream?: false} ->
        {{:ok, :ignore}, state}

      playback: %{state: playback_state} ->
        raise "Received end of stream event in an incorrect state. State: #{inspect(playback_state, pretty: true)}, on pad: #{inspect(pad_ref)}"
    end
  end

  defp handle_special_event(_pad_ref, _event, state), do: {{:ok, :handle}, state}

  defp buffers_before_event_present?(pad_data), do: not InputBuffer.empty?(pad_data.input_buf)

  defp stream_event_to_callback(%Events.StartOfStream{}), do: :handle_start_of_stream
  defp stream_event_to_callback(%Events.EndOfStream{}), do: :handle_end_of_stream
end
