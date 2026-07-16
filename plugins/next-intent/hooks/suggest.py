#!/usr/bin/env python3
"""Generate one likely next-user message when a Codex turn stops."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any
import uuid


MODEL = os.environ.get("NEXT_INTENT_MODEL", "gpt-5.6-luna")
MAX_TRANSCRIPT_BYTES = 512 * 1024


def _content_text(content: Any) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""

    parts: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") in {"input_text", "output_text", "text"}:
            text = item.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(parts).strip()


def _message_from_event(event: Any) -> tuple[str, str] | None:
    if not isinstance(event, dict):
        return None

    candidates = [event]
    payload = event.get("payload")
    if isinstance(payload, dict):
        candidates.append(payload)
        nested = payload.get("message")
        if isinstance(nested, dict):
            candidates.append(nested)

    for candidate in candidates:
        if candidate.get("type") not in {None, "message"}:
            continue
        role = candidate.get("role")
        if role not in {"user", "assistant"}:
            continue
        text = _content_text(candidate.get("content"))
        if not text and isinstance(candidate.get("text"), str):
            text = candidate["text"].strip()
        if text:
            return role, text
    return None


def recent_dialogue(transcript_path: str) -> list[tuple[str, str]]:
    path = Path(transcript_path)
    if not path.is_file():
        return []

    with path.open("rb") as handle:
        size = path.stat().st_size
        if size > MAX_TRANSCRIPT_BYTES:
            handle.seek(size - MAX_TRANSCRIPT_BYTES)
            handle.readline()
        raw = handle.read().decode("utf-8", errors="replace")

    messages: list[tuple[str, str]] = []
    for line in raw.splitlines():
        try:
            message = _message_from_event(json.loads(line))
        except json.JSONDecodeError:
            continue
        if message and (not messages or message != messages[-1]):
            messages.append(message)
    return messages[-6:]


def build_prompt(messages: list[tuple[str, str]]) -> str:
    dialogue = "\n\n".join(
        f"{('用户' if role == 'user' else 'AI')}：{text}" for role, text in messages
    )
    return f"""你是对话输入补全器。根据最近对话，猜测用户最可能发送的下一句话。

规则：
- 只输出一句补全，不要解释、前缀、引号或 Markdown。
- 使用用户当前语言。
- 简明自然；中文通常 2–16 个字，其他语言不超过 12 个词。
- 优先给出能推进当前任务的具体回复，例如“没问题，执行吧”“继续”“帮我直接修改”。
- 不要替用户增加高风险授权；涉及发布、删除、付款、外发时用确认式表达。

最近对话：
{dialogue}
"""


def clean_suggestion(value: str) -> str:
    line = next((line.strip() for line in value.splitlines() if line.strip()), "")
    line = re.sub(r"^(?:建议|补全|下一步|用户)\s*[：:]\s*", "", line)
    line = line.strip("`\"'“”‘’ ")
    if len(line) > 120:
        line = line[:117].rstrip() + "…"
    return line


def write_log(data_dir: Path, text: str) -> None:
    try:
        data_dir.mkdir(parents=True, exist_ok=True)
        (data_dir / "next-intent.log").write_text(text[-8000:], encoding="utf-8")
    except OSError:
        pass


def atomic_write(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(value, encoding="utf-8")
    os.replace(temporary, path)


def generate(prompt: str, cwd: str, data_dir: Path) -> str:
    codex = shutil.which("codex")
    if not codex:
        raise RuntimeError("codex executable was not found on PATH")

    data_dir.mkdir(parents=True, exist_ok=True)
    fd, output_name = tempfile.mkstemp(prefix="suggestion-", suffix=".txt", dir=data_dir)
    os.close(fd)
    output_path = Path(output_name)
    command = [
        codex,
        "--disable",
        "hooks",
        "exec",
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--model",
        MODEL,
        "--output-last-message",
        str(output_path),
        prompt,
    ]
    try:
        result = subprocess.run(
            command,
            cwd=cwd if Path(cwd).is_dir() else None,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=38,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(f"codex exited with {result.returncode}: {result.stdout}")
        return output_path.read_text(encoding="utf-8", errors="replace")
    finally:
        output_path.unlink(missing_ok=True)


def run_worker(request_path: Path) -> int:
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, TypeError):
        return 0

    data_dir = Path(request["data_dir"])
    request_id = request["request_id"]
    transcript_path = request.get("transcript_path")
    if not isinstance(transcript_path, str) or not transcript_path:
        return 0

    messages = recent_dialogue(transcript_path)
    if not messages or messages[-1][0] != "assistant":
        return 0

    dry_run = os.environ.get("NEXT_INTENT_DRY_RUN")
    try:
        raw = dry_run if dry_run is not None else generate(
            build_prompt(messages), str(request.get("cwd", "")), data_dir
        )
        suggestion = clean_suggestion(raw)
        if not suggestion:
            return 0
        latest_request = (data_dir / "latest-request.txt").read_text(encoding="utf-8").strip()
        if latest_request != request_id:
            return 0
        payload = {"id": request_id, "text": suggestion, "created_at": time.time()}
        atomic_write(data_dir / "suggestion.json", json.dumps(payload, ensure_ascii=False))
        atomic_write(data_dir / "latest.txt", suggestion + "\n")
    except Exception as error:  # Hooks should never break the user's turn.
        write_log(data_dir, f"{type(error).__name__}: {error}\n")
    finally:
        request_path.unlink(missing_ok=True)
    return 0


def launch_worker(hook_input: dict[str, Any]) -> int:
    data_dir = Path(os.environ.get("PLUGIN_DATA", tempfile.gettempdir()))
    data_dir.mkdir(parents=True, exist_ok=True)
    request_id = str(hook_input.get("turn_id") or uuid.uuid4())
    request = {
        "request_id": request_id,
        "transcript_path": hook_input.get("transcript_path"),
        "cwd": hook_input.get("cwd", ""),
        "data_dir": str(data_dir),
    }
    request_path = data_dir / f"request-{request_id}.json"
    atomic_write(request_path, json.dumps(request, ensure_ascii=False))
    atomic_write(data_dir / "latest-request.txt", request_id + "\n")
    log = (data_dir / "worker.log").open("a", encoding="utf-8")
    try:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--worker", str(request_path)],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        log.close()
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        return run_worker(Path(sys.argv[2]))
    try:
        hook_input = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0
    if not isinstance(hook_input, dict):
        return 0
    return launch_worker(hook_input)


if __name__ == "__main__":
    raise SystemExit(main())
