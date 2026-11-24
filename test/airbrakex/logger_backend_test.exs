defmodule Airbrakex.LoggerBackendTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Airbrakex.LoggerBackend

  @state %{level: :error, metadata: []}
  # Far below the 1s HTTP timeout: the backend must not wait on Airbrake at all.
  @max_blocking_ms 100

  setup do
    bypass = Bypass.open()
    Application.put_env(:airbrakex, :endpoint, "http://localhost:#{bypass.port}")
    Application.put_env(:airbrakex, :project_id, "project_id")
    Application.put_env(:airbrakex, :project_key, "project_key")
    Application.delete_env(:airbrakex, :ignore)
    Application.delete_env(:airbrakex, :ignore_backend)
    Application.delete_env(:airbrakex, :http_options)
    Application.delete_env(:airbrakex, :drain_on_flush)
    Application.delete_env(:airbrakex, :notice_deadline)

    on_exit(fn ->
      Enum.each(
        [:ignore, :http_options, :drain_on_flush, :notice_deadline],
        &Application.delete_env(:airbrakex, &1)
      )
    end)

    {:ok, bypass: bypass}
  end

  test "a slow Airbrake adds no latency to the logger and the notice is still sent", %{
    bypass: bypass
  } do
    test_pid = self()

    Bypass.expect_once(bypass, fn conn ->
      send(test_pid, :notice_received)
      Process.sleep(500)
      Plug.Conn.resp(conn, 201, "")
    end)

    assert handle_event_ms(error_event("slow airbrake")) < @max_blocking_ms
    assert_receive :notice_received, 1_000
    wait_for_notices()
  end

  test "an Airbrake that accepts the connection and never answers adds no latency", %{
    bypass: _bypass
  } do
    # A listening socket nobody reads from: the request hangs until recv_timeout.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    Application.put_env(:airbrakex, :endpoint, "http://localhost:#{port}")

    assert handle_event_ms(error_event("airbrake hangs")) < @max_blocking_ms

    wait_for_notices()
    :gen_tcp.close(listen)
  end

  test "an invalid max_concurrent_notices falls back to the default" do
    default = Airbrakex.Application.max_concurrent_notices()
    on_exit(fn -> Application.delete_env(:airbrakex, :max_concurrent_notices) end)

    Application.put_env(:airbrakex, :max_concurrent_notices, "20")
    assert Airbrakex.Application.max_concurrent_notices() == default

    Application.put_env(:airbrakex, :max_concurrent_notices, 0)
    assert Airbrakex.Application.max_concurrent_notices() == default

    Application.put_env(:airbrakex, :max_concurrent_notices, 3)
    assert Airbrakex.Application.max_concurrent_notices() == 3
  end

  test "drops notices instead of queueing when the supervisor is at max_children", %{
    bypass: bypass
  } do
    test_pid = self()
    max_children = Airbrakex.Application.max_concurrent_notices()
    dropped_before = Airbrakex.dropped_notices()

    Bypass.expect(bypass, fn conn ->
      send(test_pid, :notice_received)
      Process.sleep(300)
      Plug.Conn.resp(conn, 201, "")
    end)

    elapsed_ms =
      timed_ms(fn ->
        Enum.each(1..(max_children + 20), fn n ->
          LoggerBackend.handle_event(error_event("burst #{n}"), @state)
        end)
      end)

    assert elapsed_ms < @max_blocking_ms
    assert length(Task.Supervisor.children(Airbrakex.TaskSupervisor)) == max_children

    wait_for_notices()
    assert count_received(:notice_received) == max_children
    assert Airbrakex.dropped_notices() - dropped_before == 20
  end

  test "a notice that raises is contained and does not log", %{bypass: _bypass} do
    Application.put_env(:airbrakex, :ignore, fn _error -> raise "boom" end)

    log =
      capture_log(fn ->
        assert {:ok, @state} = LoggerBackend.handle_event(error_event("raises"), @state)
        wait_for_notices()
      end)

    assert log == ""
  end

  test "stays attached when the task supervisor is not running", %{bypass: _bypass} do
    :ok = Supervisor.terminate_child(Airbrakex.Supervisor, Airbrakex.TaskSupervisor)

    on_exit(fn ->
      Supervisor.restart_child(Airbrakex.Supervisor, Airbrakex.TaskSupervisor)
    end)

    dropped_before = Airbrakex.dropped_notices()

    assert {:ok, @state} = LoggerBackend.handle_event(error_event("no supervisor"), @state)
    assert Airbrakex.dropped_notices() - dropped_before == 1
  end

  test "stopping the application waits for in-flight notices", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, fn conn ->
      Process.sleep(300)
      send(test_pid, :notice_delivered)
      Plug.Conn.resp(conn, 201, "")
    end)

    LoggerBackend.handle_event(error_event("logged just before shutdown"), @state)

    # NoticeDrain is the first child the supervisor stops on shutdown.
    on_exit(fn -> Supervisor.restart_child(Airbrakex.Supervisor, Airbrakex.NoticeDrain) end)
    :ok = Supervisor.terminate_child(Airbrakex.Supervisor, Airbrakex.NoticeDrain)

    assert_received :notice_delivered
  end

  test "an explicit flush waits for in-flight notices", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, fn conn ->
      Process.sleep(300)
      send(test_pid, :notice_delivered)
      Plug.Conn.resp(conn, 201, "")
    end)

    Application.put_env(:airbrakex, :drain_on_flush, true)
    LoggerBackend.handle_event(error_event("logged just before a flush"), @state)

    assert {:ok, @state} = LoggerBackend.handle_event(:flush, @state)
    assert_received :notice_delivered
  end

  test "a flush does not wait unless drain_on_flush is set", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      Process.sleep(300)
      Plug.Conn.resp(conn, 201, "")
    end)

    LoggerBackend.handle_event(error_event("logged just before a flush"), @state)

    assert timed_ms(fn -> LoggerBackend.handle_event(:flush, @state) end) < @max_blocking_ms
    wait_for_notices()
  end

  test "a notice that outlives the deadline is stopped without logging", %{bypass: _bypass} do
    # Accepts the connection and never answers; recv_timeout is far past the deadline.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    Application.put_env(:airbrakex, :endpoint, "http://localhost:#{port}")
    Application.put_env(:airbrakex, :http_options, recv_timeout: 10_000)
    Application.put_env(:airbrakex, :notice_deadline, 100)

    log =
      capture_log(fn ->
        LoggerBackend.handle_event(error_event("airbrake trickles"), @state)
        [task] = Task.Supervisor.children(Airbrakex.TaskSupervisor)
        ref = Process.monitor(task)

        assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :airbrakex_deadline}}, 1_000
        # Give the supervisor time to report the exit, if it were going to.
        Process.sleep(50)
      end)

    assert log == ""
    :gen_tcp.close(listen)
  end

  test "an invalid notice_deadline falls back to the default" do
    default = LoggerBackend.notice_deadline()

    Enum.each(["5000", :infinity, -1, 0, 1.5], fn invalid ->
      Application.put_env(:airbrakex, :notice_deadline, invalid)
      assert LoggerBackend.notice_deadline() == default
    end)

    Application.put_env(:airbrakex, :notice_deadline, 250)
    assert LoggerBackend.notice_deadline() == 250
  end

  test "draining in-flight notices is bounded", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      Process.sleep(500)
      Plug.Conn.resp(conn, 201, "")
    end)

    LoggerBackend.handle_event(error_event("slow notice"), @state)

    {elapsed_ms, result} = timed(fn -> Airbrakex.Application.drain_notices(50) end)

    assert result == :timeout
    assert elapsed_ms < 400
    wait_for_notices()
  end

  defp error_event(message) do
    {:error, Process.group_leader(), {Logger, message, {{2026, 11, 20}, {0, 0, 0, 0}}, []}}
  end

  defp handle_event_ms(event) do
    timed_ms(fn -> assert {:ok, @state} = LoggerBackend.handle_event(event, @state) end)
  end

  defp timed_ms(fun) do
    {elapsed_ms, _result} = timed(fun)
    elapsed_ms
  end

  defp timed(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds, 1_000), result}
  end

  defp wait_for_notices do
    Airbrakex.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000 end)
  end

  defp count_received(message, count \\ 0) do
    receive do
      ^message -> count_received(message, count + 1)
    after
      0 -> count
    end
  end
end
