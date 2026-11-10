#!/usr/bin/env python3
"""fake_model.py — a stand-in model API for the engine permission tests: no real model, no network, no key.

It speaks the Anthropic Messages API (Claude Code, via ANTHROPIC_BASE_URL) and the OpenAI chat completions API
(OpenCode, via an openai-compatible provider), streaming or not. To the first request that offers the tool it
answers with one call of it: the shell tool running COMMAND or, for "write:<absolute path>", the write tool writing
that file. When the engine sends back the tool's result, the server appends it to RECORD as a JSON line and ends
the turn with a short text. Any other request gets a short text. Every request is logged to RECORD too, with the
names of the tools it offered.

Usage: python3 fake_model.py COMMAND RECORD PORT_FILE
The server picks a free port on 127.0.0.1, writes it to PORT_FILE and serves until it is killed.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COMMAND, RECORD, PORT_FILE = sys.argv[1], sys.argv[2], sys.argv[3]
WRITE = COMMAND[len("write:"):] if COMMAND.startswith("write:") else None
# The call to make, as (Anthropic tool, input) and (OpenAI tool, arguments).
if WRITE:
    CLAUDE_CALL = ("Write", {"file_path": WRITE, "content": "{}\n"})
    OPENAI_CALL = ("write", {"filePath": WRITE, "content": "{}\n"})
else:
    CLAUDE_CALL = ("Bash", {"command": COMMAND, "description": "Run the command under test"})
    OPENAI_CALL = ("bash", {"command": COMMAND, "description": "Run the command under test"})


def record(entry):
    with open(RECORD, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(text_of(item.get("text", item.get("content", ""))) if isinstance(item, dict) else str(item)
                         for item in content)
    return str(content)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, content_type="application/json"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send(200, "{}")

    def do_HEAD(self):
        self.send(200, "")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        names = [t.get("name") or t.get("function", {}).get("name") for t in body.get("tools") or []]
        record({"request": self.path, "tools": names})
        if self.path.split("?")[0].endswith("/messages/count_tokens"):
            self.send(200, json.dumps({"input_tokens": 10}))
        elif self.path.split("?")[0].endswith("/messages"):
            self.anthropic(body)
        elif self.path.split("?")[0].endswith("/chat/completions"):
            self.openai(body)
        else:
            self.send(404, json.dumps({"error": {"type": "not_found", "message": self.path}}))

    # Anthropic Messages API (Claude Code)
    def anthropic(self, body):
        results = [item for message in body.get("messages", []) if message.get("role") == "user"
                   and isinstance(message.get("content"), list)
                   for item in message["content"] if isinstance(item, dict) and item.get("type") == "tool_result"]
        offered = any(tool.get("name") == CLAUDE_CALL[0] for tool in body.get("tools") or [])
        if results:
            last = results[-1]
            record({"api": "anthropic", "tool_result": text_of(last.get("content")), "is_error": bool(last.get("is_error"))})
            block = {"type": "text", "text": "Done."}
        elif offered:
            block = {"type": "tool_use", "id": "toolu_permtest", "name": CLAUDE_CALL[0], "input": CLAUDE_CALL[1]}
        else:
            block = {"type": "text", "text": "OK"}
        stop = "tool_use" if block["type"] == "tool_use" else "end_turn"
        message = {"id": "msg_permtest", "type": "message", "role": "assistant", "model": body.get("model", "fake"),
                   "content": [block], "stop_reason": stop, "stop_sequence": None,
                   "usage": {"input_tokens": 10, "output_tokens": 5}}
        if not body.get("stream"):
            self.send(200, json.dumps(message))
            return
        start = dict(message, content=[], stop_reason=None)
        if block["type"] == "tool_use":
            opening = dict(block, input={})
            delta = {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}
        else:
            opening = {"type": "text", "text": ""}
            delta = {"type": "text_delta", "text": block["text"]}
        events = [("message_start", {"type": "message_start", "message": start}),
                  ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": opening}),
                  ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": delta}),
                  ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                  ("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                     "usage": {"output_tokens": 5}}),
                  ("message_stop", {"type": "message_stop"})]
        self.send(200, "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events),
                  "text/event-stream")

    # OpenAI chat completions API (OpenCode)
    def openai(self, body):
        messages = body.get("messages", [])
        tools = [tool.get("function", {}).get("name") for tool in body.get("tools") or []]
        results = [message for message in messages if message.get("role") == "tool"]
        if results:
            record({"api": "openai", "tool_result": text_of(results[-1].get("content")), "is_error": None})
            delta, finish = {"role": "assistant", "content": "Done."}, "stop"
        elif OPENAI_CALL[0] in tools:
            call = {"index": 0, "id": "call_permtest", "type": "function",
                    "function": {"name": OPENAI_CALL[0], "arguments": json.dumps(OPENAI_CALL[1])}}
            delta, finish = {"role": "assistant", "content": None, "tool_calls": [call]}, "tool_calls"
        else:
            delta, finish = {"role": "assistant", "content": "OK"}, "stop"
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        base = {"id": "chatcmpl-permtest", "created": 1, "model": body.get("model", "fake")}
        if not body.get("stream"):
            message = {k: v for k, v in delta.items() if k != "index"}
            if "tool_calls" in message:
                message["tool_calls"] = [{k: v for k, v in call.items() if k != "index"} for call in message["tool_calls"]]
            self.send(200, json.dumps(dict(base, object="chat.completion", usage=usage,
                                           choices=[{"index": 0, "message": message, "finish_reason": finish}])))
            return
        chunks = [dict(base, object="chat.completion.chunk",
                       choices=[{"index": 0, "delta": delta, "finish_reason": None}]),
                  dict(base, object="chat.completion.chunk",
                       choices=[{"index": 0, "delta": {}, "finish_reason": finish}]),
                  dict(base, object="chat.completion.chunk", choices=[], usage=usage)]
        self.send(200, "".join(f"data: {json.dumps(chunk)}\n\n" for chunk in chunks) + "data: [DONE]\n\n",
                  "text/event-stream")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
