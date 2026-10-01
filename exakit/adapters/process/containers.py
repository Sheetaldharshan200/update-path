"""A container engine (docker or podman) as the legacy crossing needs it: find, inspect, start, stop, port."""

from __future__ import annotations

from dataclasses import dataclass

from .runner import Runner



@dataclass(frozen=True, slots=True)
class Engine:
    name: str      # docker | podman
    path: str


def find_engine(runner: Runner, container: str, *, timeout: int, prefer: str | None = None) -> Engine | None:
    """The engine that knows the container: the recorded one when it is on PATH, else whichever answers for it."""
    if prefer:
        path = runner.which(prefer)
        return Engine(prefer, path) if path else None
    for name in ("docker", "podman"):
        path = runner.which(name)
        if path and runner.run([path, "container", "inspect", container], timeout=timeout).ok:
            return Engine(name, path)
    return None


def engine_answers(runner: Runner, engine: Engine, *, timeout: int) -> bool:
    """True when the engine answers."""
    done = runner.run([engine.path, "version", "--format", "{{.Server.Version}}"], timeout=timeout)
    return done.ok and bool(done.out.strip())


def container_state(runner: Runner, engine: Engine | None, container: str, *, timeout: int) -> str:
    """running | stopped | absent | unknown."""
    if not container:
        return "absent"
    if engine is None:
        return "unknown"
    done = runner.run([engine.path, "container", "inspect", "-f", "{{.State.Running}}", container], timeout=timeout)
    if done.ok:
        text = done.out.lower()
        return "running" if "true" in text else "stopped" if "false" in text else "unknown"
    if runner.run([engine.path, "container", "inspect", container], timeout=timeout).ok:
        return "unknown"
    return "unknown" if not engine_answers(runner, engine, timeout=timeout) else "absent"


def start_container(runner: Runner, engine: Engine, container: str, *, timeout: int) -> bool:
    """Start the container."""
    return runner.run([engine.path, "start", container], timeout=timeout).ok


def stop_container(runner: Runner, engine: Engine, container: str, *, timeout: int) -> bool:
    """Stop the container."""
    return runner.run([engine.path, "stop", container], timeout=timeout).ok


def published_port(runner: Runner, engine: Engine, container: str, *, timeout: int, inner: str = "8563/tcp") -> int | None:
    """The host port the container publishes, or None."""
    done = runner.run([engine.path, "port", container, inner], timeout=timeout)
    for line in done.out.splitlines() if done.ok else []:
        if line.startswith("["):
            continue
        port = line.rsplit(":", 1)[-1].strip()
        if port.isdigit():
            return int(port)
    return None
