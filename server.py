"""
Garmin–TickTick Proxy Server
Runs on http://localhost:8765

Endpoints:
  GET  /auth/start           → Redirect browser to TickTick OAuth page
  GET  /auth/callback        → Handle OAuth callback, save tokens
  GET  /auth/status          → Check authentication status
  GET  /tasks                → Today's due + overdue open tasks (JSON)
                               Also auto-triggers font rebuild in background
  POST /complete/<task_id>   → Mark task complete
  POST /postpone/<task_id>   → Postpone task due date by 1 day
  GET  /rebuild/status       → Check auto-rebuild progress
  POST /rebuild/trigger      → Force immediate rebuild (bypasses cooldown)
"""

import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from dotenv import load_dotenv
from flask import Flask, jsonify, redirect, request

from ticktick import TickTickClient, TokenError

load_dotenv()

app = Flask(__name__)

CLIENT_ID = os.environ["TICKTICK_CLIENT_ID"]
CLIENT_SECRET = os.environ["TICKTICK_CLIENT_SECRET"]
REDIRECT_URI = os.environ.get("REDIRECT_URI", "http://192.168.1.186:8765")
PORT = int(os.environ.get("PORT", 8765))

BASE_DIR = Path(__file__).parent
SDK_BIN  = Path(os.environ.get(
    "CIQ_SDK_BIN",
    r"C:\Users\User\AppData\Roaming\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.4.1-2026-02-03-e9f77eeaa\bin"
))

client = TickTickClient(CLIENT_ID, CLIENT_SECRET, REDIRECT_URI)

# In-memory cache: task_id → {projectId, dueDate}
# Populated on GET /tasks, consumed by /complete and /postpone
_task_cache: dict[str, dict] = {}

# ------------------------------------------------------------------
# Auto-rebuild (font generation + compile) state
# ------------------------------------------------------------------

_rebuild_lock   = threading.Lock()
_rebuild_status = "idle"   # "idle" | "running" | "done" | "error"
_rebuild_log    = ""
_last_rebuild   = 0.0
REBUILD_COOLDOWN = 300  # seconds between auto-rebuilds (5 minutes)


def _run_rebuild():
    """Background task: run gen_font.py then monkeyc."""
    global _rebuild_status, _rebuild_log

    widget_dir  = BASE_DIR / "widget"
    prg_out     = widget_dir / "bin" / "widget.prg"
    dev_key     = widget_dir / "developer_key"
    jungle_file = widget_dir / "monkey.jungle"
    monkeyc     = SDK_BIN / "monkeyc.bat"

    try:
        # Step 1: generate font
        r = subprocess.run(
            [sys.executable, str(BASE_DIR / "gen_font.py")],
            capture_output=True, text=True, timeout=120
        )
        if r.returncode != 0:
            with _rebuild_lock:
                _rebuild_status = "error"
                _rebuild_log = "gen_font failed: " + (r.stderr or r.stdout)[-300:]
            return

        # Step 2: compile widget
        r = subprocess.run(
            ["cmd", "/c", str(monkeyc),
             "-f", str(jungle_file),
             "-o", str(prg_out),
             "-y", str(dev_key),
             "-d", "fr955"],
            capture_output=True, text=True, timeout=120
        )
        if r.returncode != 0:
            with _rebuild_lock:
                _rebuild_status = "error"
                _rebuild_log = "monkeyc failed: " + (r.stderr or r.stdout)[-300:]
            return

        with _rebuild_lock:
            _rebuild_status = "done"
            _rebuild_log = "OK"
        print("  ✓  Auto-rebuild complete")

    except Exception as exc:
        with _rebuild_lock:
            _rebuild_status = "error"
            _rebuild_log = str(exc)
        print(f"  ✗  Auto-rebuild error: {exc}")


def trigger_rebuild_if_due():
    """Spawn a rebuild thread if cooldown has elapsed and none is running."""
    global _rebuild_status, _last_rebuild
    now = time.time()
    with _rebuild_lock:
        if _rebuild_status == "running":
            return
        if now - _last_rebuild < REBUILD_COOLDOWN:
            return
        _rebuild_status = "running"
        _rebuild_log    = ""
        _last_rebuild   = now
    threading.Thread(target=_run_rebuild, daemon=True).start()
    print("  → Auto-rebuild triggered")


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def ok(data=None, **kwargs):
    payload = {"ok": True}
    if data is not None:
        payload["data"] = data
    payload.update(kwargs)
    return jsonify(payload), 200


def err(message: str, code: int = 400):
    return jsonify({"ok": False, "error": message}), code


# ------------------------------------------------------------------
# Auth routes
# ------------------------------------------------------------------

@app.route("/auth/start")
def auth_start():
    """Open this URL in a browser to begin OAuth flow."""
    url = client.get_auth_url()
    return redirect(url)


@app.route("/auth/callback")
def auth_callback():
    """TickTick redirects here after user grants permission."""
    code = request.args.get("code")
    error = request.args.get("error")

    if error:
        return err(f"OAuth error: {error}")

    if not code:
        return err("Missing authorization code")

    try:
        client.exchange_code(code)
        return ok(message="Authentication successful! You can close this tab.")
    except Exception as exc:
        return err(f"Token exchange failed: {exc}", 500)


@app.route("/auth/status")
def auth_status():
    return ok(authenticated=client.is_authenticated())


# ------------------------------------------------------------------
# Task routes
# ------------------------------------------------------------------

@app.route("/debug/tasks")
def debug_tasks():
    """Return raw filter API response for debugging."""
    import requests as req
    token = client._get_access_token()
    resp = req.post(
        "https://api.ticktick.com/open/v1/task/filter",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"status": [0]},
        timeout=10,
    )
    return jsonify({"status_code": resp.status_code, "raw": resp.json()}), 200


@app.route("/lists")
def get_lists():
    """Return all TickTick projects/lists."""
    try:
        lists = client.get_lists()
    except TokenError as exc:
        return err(str(exc), 401)
    except Exception as exc:
        return err(f"Failed to fetch lists: {exc}", 502)
    return ok(lists, count=len(lists))


@app.route("/list/<project_id>/tasks")
def get_list_tasks(project_id: str):
    """Return all open tasks in a specific list."""
    global _task_cache
    try:
        tasks = client.get_list_tasks(project_id)
    except TokenError as exc:
        return err(str(exc), 401)
    except Exception as exc:
        return err(f"Failed to fetch tasks: {exc}", 502)

    for t in tasks:
        _task_cache[t["id"]] = {"projectId": t["projectId"], "dueDate": t.get("dueDate", "")}

    return ok(tasks, count=len(tasks))


@app.route("/tasks")
def get_tasks():
    """Return today's due + overdue open tasks, sorted overdue-first."""
    global _task_cache
    try:
        tasks = client.get_tasks()
    except TokenError as exc:
        return err(str(exc), 401)
    except Exception as exc:
        return err(f"Failed to fetch tasks: {exc}", 502)

    # Rebuild cache
    _task_cache = {
        t["id"]: {"projectId": t["projectId"], "dueDate": t["dueDate"]}
        for t in tasks
    }

    # Auto-trigger font + compile rebuild in background
    trigger_rebuild_if_due()

    with _rebuild_lock:
        status = _rebuild_status

    return ok(tasks, count=len(tasks), rebuildStatus=status)


@app.route("/rebuild/status")
def rebuild_status():
    """Return current auto-rebuild status."""
    with _rebuild_lock:
        return ok(status=_rebuild_status, log=_rebuild_log,
                  lastRebuild=_last_rebuild,
                  cooldownRemaining=max(0, REBUILD_COOLDOWN - (time.time() - _last_rebuild)))


@app.route("/rebuild/trigger", methods=["POST"])
def rebuild_trigger():
    """Force an immediate rebuild (bypasses cooldown)."""
    global _last_rebuild
    with _rebuild_lock:
        if _rebuild_status == "running":
            return ok(message="Already running")
        _last_rebuild = 0.0  # Reset cooldown so trigger_rebuild_if_due fires
    trigger_rebuild_if_due()
    return ok(message="Rebuild started")


@app.route("/complete/<task_id>", methods=["POST"])
def complete_task(task_id: str):
    """Mark a task as complete."""
    meta = _task_cache.get(task_id)
    if not meta:
        # Accept projectId from request body as fallback
        body = request.get_json(silent=True) or {}
        project_id = body.get("projectId", "")
    else:
        project_id = meta["projectId"]

    if not project_id:
        return err("projectId unknown. Call GET /tasks first or supply projectId in body.")

    try:
        client.complete_task(task_id, project_id)
    except TokenError as exc:
        return err(str(exc), 401)
    except Exception as exc:
        return err(f"Failed to complete task: {exc}", 502)

    _task_cache.pop(task_id, None)
    client.invalidate_cache()
    return ok(taskId=task_id, action="completed")


@app.route("/postpone/<task_id>", methods=["POST"])
def postpone_task(task_id: str):
    """Postpone a task's due date by one day."""
    meta = _task_cache.get(task_id)
    if not meta:
        body = request.get_json(silent=True) or {}
        project_id = body.get("projectId", "")
        due_date = body.get("dueDate", "")
    else:
        project_id = meta["projectId"]
        due_date = meta["dueDate"]

    if not project_id:
        return err("projectId unknown. Call GET /tasks first or supply projectId in body.")

    try:
        updated = client.postpone_task(task_id, project_id, due_date)
    except TokenError as exc:
        return err(str(exc), 401)
    except Exception as exc:
        return err(f"Failed to postpone task: {exc}", 502)

    # Update cache with new due date
    if task_id in _task_cache and updated:
        _task_cache[task_id]["dueDate"] = updated.get("dueDate", due_date)

    client.invalidate_cache()
    return ok(taskId=task_id, action="postponed")


# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------

def _warm_cache():
    """Pre-fetch tasks in background so first watch request is instant."""
    try:
        print("  → Pre-warming cache...")
        tasks = client.get_tasks()
        print(f"  ✓  Cache ready ({len(tasks)} tasks)")
    except Exception as exc:
        print(f"  ⚠  Cache warm-up failed: {exc}")


if __name__ == "__main__":
    print(f"Starting Garmin-TickTick proxy on http://localhost:{PORT}")
    print()
    if not client.is_authenticated():
        print("  ⚠  Not authenticated yet.")
        print(f"  → Open http://localhost:{PORT}/auth/start in your browser to connect TickTick.")
    else:
        print("  ✓  Token loaded from token.json")
        threading.Thread(target=_warm_cache, daemon=True).start()
    print()
    app.run(host="0.0.0.0", port=PORT, debug=False)
