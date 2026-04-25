"""
TickTick API client with OAuth 2.0 token management.
"""

import json
import os
import time
import unicodedata

try:
    from pypinyin import lazy_pinyin
    _HAS_PINYIN = True
except ImportError:
    _HAS_PINYIN = False


def _to_ascii_title(text: str) -> str:
    """Convert CJK characters to pinyin; leave ASCII unchanged."""
    if _HAS_PINYIN:
        return " ".join(lazy_pinyin(text))
    # Fallback: strip non-ASCII
    return "".join(c if ord(c) < 128 else "?" for c in text)
from datetime import datetime, timedelta, timezone

TAIPEI_TZ = timezone(timedelta(hours=8))
from pathlib import Path

import requests

_token_dir = Path(os.environ.get("TOKEN_DIR", str(Path(__file__).parent)))
TOKEN_FILE = _token_dir / "token.json"
BASE_URL = "https://api.ticktick.com/open/v1"
AUTH_URL = "https://ticktick.com/oauth/authorize"
TOKEN_URL = "https://ticktick.com/oauth/token"


class TokenError(Exception):
    pass


class TickTickClient:
    def __init__(self, client_id: str, client_secret: str, redirect_uri: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self._tokens: dict = {}

        if TOKEN_FILE.exists():
            self._load_tokens()

    # ------------------------------------------------------------------
    # Token management
    # ------------------------------------------------------------------

    def _load_tokens(self):
        with open(TOKEN_FILE, "r") as f:
            self._tokens = json.load(f)

    def _save_tokens(self):
        with open(TOKEN_FILE, "w") as f:
            json.dump(self._tokens, f, indent=2)

    def is_authenticated(self) -> bool:
        return bool(self._tokens.get("access_token"))

    def _is_token_expired(self) -> bool:
        expires_at = self._tokens.get("expires_at", 0)
        # Refresh 60 seconds before actual expiry
        return time.time() >= (expires_at - 60)

    def get_auth_url(self, state: str = "garmin_ticktick") -> str:
        params = {
            "client_id": self.client_id,
            "response_type": "code",
            "redirect_uri": self.redirect_uri,
            "scope": "tasks:read tasks:write",
            "state": state,
        }
        query = "&".join(f"{k}={v}" for k, v in params.items())
        return f"{AUTH_URL}?{query}"

    def exchange_code(self, code: str):
        """Exchange authorization code for access + refresh tokens."""
        resp = requests.post(
            TOKEN_URL,
            auth=(self.client_id, self.client_secret),
            data={
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": self.redirect_uri,
            },
        )
        resp.raise_for_status()
        self._store_token_response(resp.json())

    def _refresh_tokens(self):
        refresh_token = self._tokens.get("refresh_token")
        if not refresh_token:
            raise TokenError("No refresh token available. Please re-authenticate.")

        resp = requests.post(
            TOKEN_URL,
            auth=(self.client_id, self.client_secret),
            data={
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
            },
        )
        resp.raise_for_status()
        self._store_token_response(resp.json())

    def _store_token_response(self, data: dict):
        self._tokens = {
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token", self._tokens.get("refresh_token")),
            "expires_at": time.time() + data.get("expires_in", 3600),
            "token_type": data.get("token_type", "Bearer"),
        }
        self._save_tokens()

    def _get_access_token(self) -> str:
        if not self.is_authenticated():
            raise TokenError("Not authenticated. Visit /auth/start to begin OAuth flow.")
        if self._is_token_expired():
            self._refresh_tokens()
        return self._tokens["access_token"]

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self._get_access_token()}",
            "Content-Type": "application/json",
        }

    # ------------------------------------------------------------------
    # API calls
    # ------------------------------------------------------------------

    # Simple cache: (_tasks_cache, _cache_time)
    _tasks_cache: list = []
    _cache_time: float = 0.0
    CACHE_TTL = 60  # seconds

    def get_tasks(self) -> list[dict]:
        """
        Fetch tasks due exactly today using the Filter API (single request).
        Results are cached for CACHE_TTL seconds.
        """
        now = time.time()
        if self._tasks_cache and (now - self._cache_time) < self.CACHE_TTL:
            return self._tasks_cache

        # 台北時間今天的日期（TickTick 任務以台北時區儲存）
        today = datetime.now(TAIPEI_TZ).date()

        # Filter API 的 startDate/endDate 是篩選 task.startDate 欄位，不是 dueDate
        # 所以只傳 status，再用 dueDate 在 Python 端過濾
        resp = requests.post(
            f"{BASE_URL}/task/filter",
            headers=self._headers(),
            json={"status": [0]},
            timeout=10,
        )
        resp.raise_for_status()

        result = []
        for task in resp.json():
            due_raw = task.get("dueDate") or task.get("due_date")
            if not due_raw:
                continue
            try:
                due_dt = datetime.fromisoformat(due_raw.replace("+0000", "+00:00"))
                due_date = due_dt.astimezone(TAIPEI_TZ).date()
            except (ValueError, AttributeError):
                continue
            if due_date == today:
                result.append({
                    "id": task["id"],
                    "projectId": task.get("projectId", ""),
                    "title": task.get("title", "(no title)"),
                    "dueDate": due_raw,
                    "priority": task.get("priority", 0),
                    "isOverdue": False,
                })

        result.sort(key=lambda t: -t["priority"])
        self._tasks_cache = result
        self._cache_time = time.time()
        return result

    def invalidate_cache(self) -> None:
        self._tasks_cache = []
        self._cache_time = 0.0

    def get_lists(self) -> list[dict]:
        """Return all TickTick projects/lists."""
        resp = requests.get(f"{BASE_URL}/project", headers=self._headers())
        resp.raise_for_status()
        projects = resp.json()
        return [
            {"id": p["id"], "name": p.get("name", "(unnamed)")}
            for p in projects if p.get("id")
        ]

    def get_list_tasks(self, project_id: str) -> list[dict]:
        """Return all open tasks in a specific project, sorted by priority."""
        resp = requests.get(
            f"{BASE_URL}/project/{project_id}/data",
            headers=self._headers(),
            timeout=8,
        )
        resp.raise_for_status()
        tasks = resp.json().get("tasks") or []
        today = datetime.now(TAIPEI_TZ).date()
        result = []
        for task in tasks:
            if task.get("status", 0) == 2:
                continue
            due_raw = task.get("dueDate") or task.get("due_date") or ""
            is_overdue = False
            if due_raw:
                try:
                    due_dt = datetime.fromisoformat(due_raw.replace("+0000", "+00:00"))
                    is_overdue = due_dt.astimezone(TAIPEI_TZ).date() < today
                except (ValueError, AttributeError):
                    pass
            result.append({
                "id": task["id"],
                "projectId": project_id,
                "title": task.get("title", "(no title)"),
                "dueDate": due_raw,
                "priority": task.get("priority", 0),
                "isOverdue": is_overdue,
            })
        result.sort(key=lambda t: (not t["isOverdue"], -t["priority"]))
        return result

    def complete_task(self, task_id: str, project_id: str):
        """Mark a task as complete."""
        resp = requests.post(
            f"{BASE_URL}/project/{project_id}/task/{task_id}/complete",
            headers=self._headers(),
        )
        resp.raise_for_status()

    def postpone_task(self, task_id: str, project_id: str, current_due: str):
        """Push a task's due date forward by one day."""
        try:
            due_str = current_due.replace("+0000", "+00:00")
            due_dt = datetime.fromisoformat(due_str)
        except (ValueError, AttributeError):
            # Fallback: use tomorrow
            due_dt = datetime.now(timezone.utc)

        new_due = due_dt + timedelta(days=1)
        # TickTick expects the date in the same format it gave us
        new_due_str = new_due.strftime("%Y-%m-%dT%H:%M:%S.000+0000")

        payload = {
            "id": task_id,
            "projectId": project_id,
            "dueDate": new_due_str,
        }
        resp = requests.post(
            f"{BASE_URL}/task/{task_id}",
            headers=self._headers(),
            json=payload,
        )
        resp.raise_for_status()
        return resp.json()
