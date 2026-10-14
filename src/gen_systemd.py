#!/usr/bin/env python3
"""gen_systemd.py

Responsibility: generates (and optionally installs) the MooVoidSMP systemd units.

Settings come from a JSON config (run this script with --init to generate)
Any setting can be overridden on the command line. Command line args always take priority over config file values, config file values take priority over defaults.

Generates:
  <name>.service          Bedrock server (runs the manager script)
  <name>-restart.service  oneshot that calls "<manager> <restart_arg>"
  <name>-restart.timer    schedules the restart service
  <name>-api.service      node API hook (defer-api.js)

Standard library only (Python 3.11+)
"""

# /// script
# requires-python = ">=3.11,<4.0"
# dependencies = []
# ///

from __future__ import annotations

import argparse
import getpass
import json
import os
import pwd
import re
import shutil
import subprocess
from typing import NoReturn
import sys
from dataclasses import dataclass, field
from pathlib import Path

UNIT_DIR = Path("/etc/systemd/system")
DEFAULT_CONFIG = Path(__file__).resolve().with_name("gen_systemd.json")


def die(msg: str) -> NoReturn:
    """Print an error message to stderr and exit with status 1."""
    sys.exit(f"error: {msg}")


def require_systemd() -> None:
    """Exit unless systemd is usable (only needed for install/uninstall)."""
    if not shutil.which("systemctl"):
        die("systemctl not found; systemd is required to install or uninstall units")
    if not UNIT_DIR.is_dir():
        die(f"{UNIT_DIR} not found or inaccessible")


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[bytes]:
    """Execute a subprocess command."""
    return subprocess.run(cmd, check=check)


DEFAULTS: dict = {
    "user": None,
    "name": "moovoidsmp",
    "label": "MooVoidSMP",
    "base_dir": None,
    "server_dir": None,
    "manager": None,
    "restart_arg": "restart",
    "api_script": None,
    "node": None,
    "interval_hours": 5,
    "start": "03:30",
    "on_calendar": [],
    "api": True,
    "timer": True,
    "out_dir": "systemd",
}

ACTIONS = ("dry_run", "install", "enable", "now", "uninstall", "init", "force")


@dataclass
class Config:
    """Configuration container for systemd unit generation."""

    user: str
    name: str
    label: str
    base_dir: Path
    server_dir: Path
    manager: Path
    restart_arg: str
    api_script: Path
    node: Path | None
    interval_hours: int
    start: str
    on_calendar: list[str] = field(default_factory=list)
    with_api: bool = True
    with_timer: bool = True
    calendars: list[str] = field(default_factory=list)

    @property
    def u_main(self) -> str:
        """Return the main service unit filename."""
        return f"{self.name}.service"

    @property
    def u_restart_svc(self) -> str:
        """Return the restart service unit filename."""
        return f"{self.name}-restart.service"

    @property
    def u_restart_tmr(self) -> str:
        """Return the restart timer unit filename."""
        return f"{self.name}-restart.timer"

    @property
    def u_api(self) -> str:
        """Return the API service unit filename."""
        return f"{self.name}-api.service"

    def unit_names(self) -> list[str]:
        """Return a list of all active unit filenames based on configuration."""
        names = [self.u_main]
        if self.with_timer:
            names += [self.u_restart_svc, self.u_restart_tmr]
        if self.with_api:
            names.append(self.u_api)
        return names


def die(msg: str) -> None:
    """Print an error message to stderr and exit with status 1."""
    sys.exit(f"error: {msg}")


def warn(msg: str) -> None:
    """Print a warning message to stderr."""
    print(f"warning: {msg}", file=sys.stderr)


def version_key(p: Path) -> tuple[int, ...]:
    """Generate a sort key for versioned node installation paths."""
    m = re.search(r"/v(\d+(?:\.\d+)*)/", str(p))
    return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)


def find_node(home: Path) -> Path | None:
    """Locate the Node.js executable in system PATH or NVM directories."""
    found = shutil.which("node")
    if found and not found.startswith("/root/"):
        return Path(found)
    candidates = sorted((home / ".nvm/versions/node").glob("*/bin/node"), key=version_key)
    return candidates[-1] if candidates else None


def build_calendars(interval: int, start: str) -> list[str]:
    """Build a list of systemd OnCalendar specifications based on interval and start time."""
    if not 1 <= interval <= 24:
        die("interval_hours must be an integer 1-24")
    if not re.fullmatch(r"([01]?\d|2[0-3]):[0-5]\d", start):
        die("start must be HH:MM (24h)")
    h, m = (int(x) for x in start.split(":"))
    step = interval * 60
    cur = (h * 60 + m) % step
    out = []
    while cur < 1440:
        out.append(f"*-*-* {cur // 60:02d}:{cur % 60:02d}:00")
        cur += step
    return out


def sudo_prefix() -> list[str]:
    """Return sudo command prefix if not running as root."""
    return [] if os.geteuid() == 0 else ["sudo"]


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Execute a subprocess command."""
    return subprocess.run(cmd, check=check)


def user_path(value: str | os.PathLike, home: Path) -> Path:
    """Expand a leading tilde to the target service user's home directory."""
    s = os.fspath(value)
    if s == "~":
        return home
    if s.startswith("~/"):
        return home / s[2:]
    return Path(s)


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments and flags."""
    p = argparse.ArgumentParser(
        description="Generate (and optionally install) the MooVoidSMP systemd units. "
                    "Settings come from a JSON config; flags below override it.",
        argument_default=argparse.SUPPRESS,
    )
    p.add_argument("--config", type=Path,
                   help=f"config file (default: {DEFAULT_CONFIG.name} next to this script)")

    g = p.add_argument_group("setting overrides (same names as the config keys)")
    g.add_argument("--user")
    g.add_argument("--name")
    g.add_argument("--label")
    g.add_argument("--base-dir")
    g.add_argument("--server-dir")
    g.add_argument("--manager")
    g.add_argument("--restart-arg")
    g.add_argument("--api-script")
    g.add_argument("--node")
    g.add_argument("--interval-hours", type=int)
    g.add_argument("--start")
    g.add_argument("--on-calendar", action="append", metavar="SPEC")
    g.add_argument("--no-api", dest="api", action="store_const", const=False)
    g.add_argument("--no-timer", dest="timer", action="store_const", const=False)
    g.add_argument("--out-dir")

    a = p.add_argument_group("actions")
    a.add_argument("--init", action="store_true",
                   help="write a config file filled with the resolved settings, then exit")
    a.add_argument("--force", action="store_true", help="with --init: overwrite an existing config")
    a.add_argument("--dry-run", action="store_true", help="print units to stdout, write nothing")
    a.add_argument("--install", action="store_true",
                   help=f"copy units to {UNIT_DIR} and daemon-reload (uses sudo if needed)")
    a.add_argument("--enable", action="store_true", help="with --install: enable server, timer and api")
    a.add_argument("--now", action="store_true", help="with --enable: also start them")
    a.add_argument("--uninstall", action="store_true", help="stop, disable and remove the units")
    return p.parse_args()


def load_config_file(path: Path, required: bool) -> dict:
    """Load and validate configuration from a JSON file."""
    if not path.exists():
        if required:
            die(f"config file not found: {path}")
        return {}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        die(f"{path}: invalid JSON ({e})")
    if not isinstance(data, dict):
        die(f"{path}: top level must be a JSON object")
    unknown = sorted(set(data) - set(DEFAULTS))
    if unknown:
        die(f"{path}: unknown key(s): {', '.join(unknown)} (valid: {', '.join(DEFAULTS)})")
    if isinstance(data.get("on_calendar"), str):
        data["on_calendar"] = [data["on_calendar"]]
    return {k: v for k, v in data.items() if v is not None}


def resolve(settings: dict) -> Config:
    """Resolve raw settings dictionary into a validated Config instance."""
    user = settings["user"] or os.environ.get("SUDO_USER") or getpass.getuser()
    try:
        home = Path(pwd.getpwnam(user).pw_dir)
    except KeyError:
        die(f"user '{user}' not found")

    base = user_path(settings["base_dir"], home) if settings["base_dir"] else home / "MooVoidSMP"
    server_dir = user_path(settings["server_dir"], home) if settings["server_dir"] else base / "SMP"
    manager = user_path(settings["manager"], home) if settings["manager"] else server_dir / "bds-manager.sh"
    api_script = (user_path(settings["api_script"], home) if settings["api_script"]
                  else base / "bdsmanager/src/defer-api.js")

    with_api = bool(settings["api"])
    node = user_path(settings["node"], home) if settings["node"] else None
    if with_api and node is None:
        node = find_node(home)
        if node is None:
            warn("no node binary found; skipping API unit (set \"node\" in the config to include it)")
            with_api = False

    with_timer = bool(settings["timer"])
    on_calendar = list(settings["on_calendar"])
    calendars = on_calendar
    if with_timer and not calendars:
        calendars = build_calendars(int(settings["interval_hours"]), settings["start"])

    return Config(
        user=user, name=settings["name"], label=settings["label"], base_dir=base,
        server_dir=server_dir, manager=manager, restart_arg=settings["restart_arg"],
        api_script=api_script, node=node, interval_hours=int(settings["interval_hours"]),
        start=settings["start"], on_calendar=on_calendar, with_api=with_api,
        with_timer=with_timer, calendars=calendars,
    )


def config_to_json(c: Config, out_dir: str) -> str:
    """Serialize a Config instance to a formatted JSON string."""
    data = {
        "user": c.user,
        "name": c.name,
        "label": c.label,
        "base_dir": str(c.base_dir),
        "server_dir": str(c.server_dir),
        "manager": str(c.manager),
        "restart_arg": c.restart_arg,
        "api_script": str(c.api_script),
        "node": str(c.node) if c.node else None,
        "interval_hours": c.interval_hours,
        "start": c.start,
        "on_calendar": c.on_calendar,
        "api": c.with_api,
        "timer": c.with_timer,
        "out_dir": out_dir,
    }
    return json.dumps(data, indent=2) + "\n"


def render_units(c: Config) -> dict[str, str]:
    """Render systemd unit file contents for the given configuration."""
    units: dict[str, str] = {}

    units[c.u_main] = f"""\
[Unit]
Description={c.label} Bedrock Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={c.user}
WorkingDirectory={c.server_dir}
ExecStart={c.manager}
KillSignal=SIGTERM
TimeoutStopSec=300
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
"""

    if c.with_timer:
        units[c.u_restart_svc] = f"""\
[Unit]
Description=Trigger {c.label} manager restart script

[Service]
Type=oneshot
User={c.user}
ExecStart={c.manager} {c.restart_arg}
"""
        on_calendar = "\n".join(f"OnCalendar={cal}" for cal in c.calendars)
        units[c.u_restart_tmr] = f"""\
[Unit]
Description=Timer for {c.label} routine restarts

[Timer]
{on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
"""

    if c.with_api:
        units[c.u_api] = f"""\
[Unit]
Description={c.label} Manager API Hook
After=network.target

[Service]
Type=simple
User={c.user}
WorkingDirectory={c.server_dir}
ExecStart={c.node} {c.api_script}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
"""
    return units


def uninstall(c: Config) -> None:
    """Stop, disable, and remove generated systemd units from the system."""
    sudo = sudo_prefix()
    names = [c.u_main, c.u_restart_tmr, c.u_restart_svc, c.u_api]
    for n in names:
        run(sudo + ["systemctl", "disable", "--now", n], check=False)
        run(sudo + ["rm", "-f", str(UNIT_DIR / n)])
    run(sudo + ["systemctl", "daemon-reload"])
    print("Removed:", " ".join(names))


def install(c: Config, out_dir: Path, enable: bool, now: bool) -> None:
    """Install rendered systemd units to the system unit directory and reload daemon."""
    sudo = sudo_prefix()
    for n in c.unit_names():
        run(sudo + ["install", "-m", "644", str(out_dir / n), str(UNIT_DIR / n)])
    run(sudo + ["systemctl", "daemon-reload"])
    print(f"installed to {UNIT_DIR}")

    if enable:
        to_enable = [c.u_main]
        if c.with_timer:
            to_enable.append(c.u_restart_tmr)
        if c.with_api:
            to_enable.append(c.u_api)
        run(sudo + ["systemctl", "enable"] + (["--now"] if now else []) + to_enable)
        print("enabled:", " ".join(to_enable), "(started)" if now else "")


def main() -> None:
    """Execute main application entry point."""
    cli = vars(parse_args())
    given_config: Path | None = cli.pop("config", None)
    config_path = given_config or DEFAULT_CONFIG
    act = {k: cli.pop(k, False) for k in ACTIONS}

    file_cfg = load_config_file(config_path, required=given_config is not None and not act["init"])
    settings = {**DEFAULTS, **file_cfg, **cli}
    c = resolve(settings)

    out_dir = Path(settings["out_dir"]).expanduser()
    if "out_dir" not in cli and not out_dir.is_absolute():
        out_dir = config_path.resolve().parent / out_dir

    if act["init"]:
        if config_path.exists() and not act["force"]:
            die(f"{config_path} already exists (use --force to overwrite)")
        config_path.write_text(config_to_json(c, settings["out_dir"]))
        print(f"wrote {config_path}")
        return

    if act["install"] or act["uninstall"]:
        require_systemd()

    if act["uninstall"]:
        uninstall(c)
        return

    if not c.manager.exists():
        warn(f"manager script not found: {c.manager}")
    if c.with_api and not c.api_script.exists():
        warn(f"API script not found: {c.api_script}")

    units = render_units(c)

    if act["dry_run"]:
        for name, text in units.items():
            print(f"# ===== {name} =====\n{text}")
        return

    out_dir.mkdir(parents=True, exist_ok=True)
    for name, text in units.items():
        (out_dir / name).write_text(text)
        print(f"wrote {out_dir / name}")

    if shutil.which("systemd-analyze"):
        print("--- systemd-analyze verify ---")
        run(["systemd-analyze", "verify", *(str(out_dir / n) for n in units)], check=False)

    if act["install"]:
        install(c, out_dir, act["enable"], act["now"])
    else:
        print(f"\nNot installed. To install:  {Path(sys.argv[0]).name} --install --enable  (add --now to start)")


if __name__ == "__main__":
    main()
