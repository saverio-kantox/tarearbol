defmodule Tarearbol.DynamicManager do
  @moduledoc ~S"""
  The scaffold implementation to dynamically manage many similar tasks running
  as processes.

  It creates a main supervisor, managing the `GenServer` holding the state and
  `DynamicSupervisor` handling chidren. It has a strategy `:rest_for_one`,
  assuming that if the process holding the state crashes, the children will be
  restarted.

  Typically one calls `use Tarearbol.DynamicManager` and implements at least
  `children_specs/0` callback and receives back supervised tree with a state
  and many processes controlled by `DynamicSupervisor`.

  To see how it works you might try

      defmodule DynamicManager do
        use Tarearbol.DynamicManager

        def children_specs do
          for i <- 1..10, do: {"foo_#{i}", []}, into: %{}
        end
      end

      {:ok, pid} = DynamicManager.start_link()

  The above would spawn `10` children with IDs `"foo1".."foo10"`.

  ---

  `DynamicManager` also allows dynamic workers management. It exports three
  functions

      @spec put(id :: binary(), opts :: Enum.t()) :: pid()
      @spec del(id :: binary()) :: :ok
      @spec get(id :: binary()) :: Enum.t()

  The semantics of `put/2` arguments is the same as a single `child_spec`,
  `del/1` and `get/1` receive the unique ID of the child and shutdown it or
  return it’s payload respectively.

  """
  @moduledoc since: "0.9.0"

  @doc """
  This function is called to retrieve the map of children with name as key
  and a workers as the value.

  The value must be an enumerable with keys among:
  - `:payload` (passed as second argument to `perform/2`, default `nil`)
  - `:timeout` (time between iterations of `perform/2`, default `1` second)
  - `:lull` (threshold to notify latency in performing, default `1.1` (the threshold is `:lull` times the `:timeout`))

  This function should not care about anything save for producing side effects.

  It will be backed by `DynamicSupervisor`. The value it returns will be put
  into the state under `children` key.
  """
  @doc since: "0.9.0"
  @callback children_specs :: %{required(binary()) => Enum.t()}

  @doc """
  The main function, doing all the job, supervised.

  It will be called with the child `id` as first argument and the
  `payload` option to child spec as second argument (defaulting to nil,
  can also be ignored if not needed).

  ### Return values

  `perform/2` might return

  - `:halt` if it wants to be killed
  - `{:ok, result}` to store the last result and reschedule with default timeout
  - `{:replace, id, payload}` to replace the current worker with the new one
  - `{{:timeout, timeout}, result}` to store the last result and reschedule in given timeout interval
  - or **_deprecated_** anything else will be treated as a result
  """
  @doc since: "0.9.0"
  @callback perform(id :: binary(), payload :: term()) :: any()

  @doc """
  Declares an instance-wide callback to report state; if the startup process
  takes a while, it’d be run in `handle_continue/2` and this function will be
  called after it finishes so that the application might start using it.

  If the application is not interested in receiving state updates, e. g. when
  all it needs from runners is a side effect, there is a default implementation
  that does nothing.
  """
  @doc since: "0.9.0"
  @callback handle_state_change(state :: :down | :up | :starting | :unknown) :: :ok | :restart

  @doc """
  Declares a callback to report slow process (when the scheduler cannot process
  in a reasonable time).
  """
  @doc since: "0.9.5"
  @callback handle_timeout(state :: map()) :: any()

  defmodule Child do
    @moduledoc false
    defstruct [:pid, :value]
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep do
      @namespace Keyword.get(unquote(opts), :namespace, __MODULE__)
      @doc false
      @spec namespace :: module()
      def namespace, do: @namespace

      @spec child_mod(module :: module()) :: module()
      defp child_mod(module) when is_atom(module), do: child_mod(Module.split(module))

      defp child_mod(module) when is_list(module),
        do: Module.concat(@namespace, List.last(module))

      @doc false
      @spec internal_worker_module :: module()
      def internal_worker_module, do: child_mod(Tarearbol.InternalWorker)

      @doc false
      @spec dynamic_supervisor_module :: module()
      def dynamic_supervisor_module, do: child_mod(Tarearbol.DynamicSupervisor)

      state_module_ast =
        quote location: :keep do
          @moduledoc false
          use GenServer

          defstruct state: :down, children: %{}, manager: nil

          @type t :: %{}

          def start_link(manager: manager),
            do: GenServer.start_link(__MODULE__, [manager: manager], name: __MODULE__)

          @spec state :: State.t()
          def state, do: GenServer.call(__MODULE__, :state)

          @spec update_state(state :: :down | :up | :starting | :unknown) :: :ok
          def update_state(state), do: GenServer.cast(__MODULE__, {:update_state, state})

          @spec put(id :: binary(), props :: map()) :: :ok
          def put(id, props), do: GenServer.cast(__MODULE__, {:put, id, props})

          @spec del(id :: binary()) :: :ok
          def del(id), do: GenServer.cast(__MODULE__, {:del, id})

          @spec get(id :: binary()) :: :ok
          def get(id, default \\ nil),
            do: GenServer.call(__MODULE__, {:get, id, default})

          @impl GenServer
          def init(opts) do
            state = struct(__MODULE__, Keyword.put(opts, :state, :starting))

            state.manager.handle_state_change(:starting)
            {:ok, state}
          end

          @impl GenServer
          def handle_call(:state, _from, %__MODULE__{} = state),
            do: {:reply, state, state}

          @impl GenServer
          def handle_call(
                {:get, id, default},
                _from,
                %__MODULE__{children: children} = state
              ),
              do: {:reply, Map.get(children, id, default), state}

          @impl GenServer
          def handle_cast(
                {:put, id, %Tarearbol.DynamicManager.Child{} = props},
                %__MODULE__{children: children} = state
              ),
              do: {:noreply, %{state | children: Map.put(children, id, props)}}

          @impl GenServer
          def handle_cast({:put, id, props}, %__MODULE__{children: children} = state) do
            children = Map.put(children, id, struct(Tarearbol.DynamicManager.Child, props))
            {:noreply, %{state | children: children}}
          end

          @impl GenServer
          def handle_cast({:del, id}, %__MODULE__{children: children} = state),
            do: {:noreply, %{state | children: Map.delete(children, id)}}

          @impl GenServer
          def handle_cast({:update_state, new_state}, %__MODULE__{} = state),
            do: {:noreply, %{state | state: new_state}}
        end

      Module.create(Module.concat(@namespace, State), state_module_ast, __ENV__)
      @doc false
      @spec state_module :: module()
      def state_module, do: Module.concat(@namespace, State)

      require Logger

      @behaviour Tarearbol.DynamicManager

      @impl Tarearbol.DynamicManager
      def perform(id, _payload) do
        Logger.warn(
          "perform for id[#{id}] was executed with state\n\n" <>
            inspect(state_module().state()) <>
            "\n\nyou want to override `perform/2` in your #{inspect(__MODULE__)}\n" <>
            "to perform some actual work instead of printing this message"
        )

        if Enum.random(1..3) == 1, do: :halt, else: :ok
      end

      defoverridable perform: 2

      @impl Tarearbol.DynamicManager
      def handle_state_change(state),
        do: Logger.info("[#{inspect(__MODULE__)}] state has changed to #{state}")

      defoverridable handle_state_change: 1

      @impl Tarearbol.DynamicManager
      def handle_timeout(state), do: Logger.warn("A worker is too slow [#{inspect(state)}]")

      defoverridable handle_timeout: 1

      use Supervisor

      @doc """
      Starts the `DynamicSupervisor` and its helpers to manage dynamic children
      """
      def start_link(opts \\ []),
        do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

      @impl Supervisor
      def init(opts) do
        children = [
          {Registry, [keys: :unique, name: Module.concat(@namespace, Registry)]},
          {state_module(), [manager: __MODULE__]},
          {Tarearbol.DynamicSupervisor, Keyword.put(opts, :manager, __MODULE__)},
          {Tarearbol.InternalWorker, [manager: __MODULE__]}
        ]

        Logger.info(
          "Starting #{inspect(__MODULE__)} with following children:\n" <>
            "    State → #{inspect(state_module())}\n" <>
            "    DynamicSupervisor → #{inspect(dynamic_supervisor_module())}\n" <>
            "    InternalWorker → #{inspect(internal_worker_module())}"
        )

        Supervisor.init(children, strategy: :rest_for_one)
      end

      @doc """
      Dynamically adds a supervised worker implementing `Tarearbol.DynamicManager`
      behaviour to the list of supervised children
      """
      def put(id, opts), do: Tarearbol.InternalWorker.put(internal_worker_module(), id, opts)

      @doc """
      Dynamically removes a supervised worker implementing `Tarearbol.DynamicManager`
      behaviour from the list of supervised children
      """
      def del(id), do: Tarearbol.InternalWorker.del(internal_worker_module(), id)

      @doc """
      Retrieves the information (`payload`, `timeout`, `lull` etc.) assotiated with
      the supervised worker
      """
      def get(id), do: Tarearbol.InternalWorker.get(internal_worker_module(), id)
    end
  end
end
