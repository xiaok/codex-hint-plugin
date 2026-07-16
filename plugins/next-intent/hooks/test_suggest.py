import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import suggest


class SuggestTests(unittest.TestCase):
    def test_reads_recent_dialogue(self):
        events = [
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "给我一个方案"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "建议分三步执行。"}]}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "transcript.jsonl"
            path.write_text("\n".join(json.dumps(item, ensure_ascii=False) for item in events), encoding="utf-8")
            self.assertEqual(
                suggest.recent_dialogue(str(path)),
                [("user", "给我一个方案"), ("assistant", "建议分三步执行。")],
            )

    def test_cleans_model_wrapping(self):
        self.assertEqual(suggest.clean_suggestion("下一步：“没问题，执行吧”\n解释"), "没问题，执行吧")

    def test_worker_writes_fresh_suggestion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            transcript.write_text("\n".join([
                json.dumps({"payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "给我一个方案"}]}}),
                json.dumps({"payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "建议分三步执行。"}]}}),
            ]), encoding="utf-8")
            request = root / "request-turn-1.json"
            request.write_text(json.dumps({
                "request_id": "turn-1",
                "transcript_path": str(transcript),
                "cwd": directory,
                "data_dir": directory,
            }), encoding="utf-8")
            (root / "latest-request.txt").write_text("turn-1\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {"NEXT_INTENT_DRY_RUN": "没问题，执行吧"}):
                self.assertEqual(suggest.run_worker(request), 0)

            payload = json.loads((root / "suggestion.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["id"], "turn-1")
            self.assertEqual(payload["text"], "没问题，执行吧")
            self.assertFalse(request.exists())


if __name__ == "__main__":
    unittest.main()
