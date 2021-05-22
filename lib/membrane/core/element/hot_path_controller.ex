defmodule Membrane.Core.Element.HotPathController do
  alias Membrane.Core.Message

  def handle_buffer(pad_ref, buffers, state) do
    size = length(buffers)

    case state do
      %{
        pads: %{
          data: %{
            ^pad_ref =>
              %Membrane.Pad.Data{
                direction: :input,
                mode: :pull,
                sticky_messages: [],
                input_buf: %{current_size: 0, demand: ib_demand} = input_buf,
                start_of_stream?: true,
                end_of_stream?: false,
                demand: demand
              } = pad_data
          }
        },
        playback: %{state: :playing},
        type: type,
        module: module
      }
      when demand >= size ->
        ib_demand = ib_demand + size

        state =
          if ib_demand > 0 do
            to_demand = max(ib_demand, input_buf.min_demand)
            Message.send(pad_data.pid, :demand, to_demand, for_pad: pad_data.other_ref)
            put_in(state.pads.data[pad_ref].input_buf.demand, ib_demand - to_demand)
          else
            put_in(state.pads.data[pad_ref].input_buf.demand, ib_demand)
          end

        state = %{state | supplying_demand?: true}

        callback =
          case type do
            :filter -> :handle_process
            :sink -> :handle_write
          end

        state = do_handle_buffers(buffers, pad_ref, module, callback, state)
        state = %{state | supplying_demand?: false}
        {:ok, state} = Membrane.Core.Element.DemandHandler.handle_delayed_demands(state)
        {:match, state}

      _state ->
        :no_match
    end
  end

  defp do_handle_buffers([], _pad_ref, _module, _callback, state) do
    state
  end

  defp do_handle_buffers([buffer | buffers], pad_ref, module, callback, state) do
    context = %{pads: state.pads.data, playback_state: :playing}
    state = update_in(state.pads.data[pad_ref].demand, &(&1 - 1))

    state =
      case apply(module, callback, [pad_ref, buffer, context, state.internal_state]) do
        {{:ok, actions}, internal_state} ->
          state = %{state | internal_state: internal_state}

          {:ok, state} =
            Membrane.Core.Element.ActionHandler.handle_actions(
              actions,
              callback,
              %{},
              state
            )

          state

        {:ok, internal_state} ->
          %{state | internal_state: internal_state}
      end

    do_handle_buffers(buffers, pad_ref, module, callback, state)
  end
end
