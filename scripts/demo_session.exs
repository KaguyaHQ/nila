unless Code.ensure_loaded?(Nila.DemoSession),
  do: Code.require_file("../lib/nila/demo_session.ex", __DIR__)
