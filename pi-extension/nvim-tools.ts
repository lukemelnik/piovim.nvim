import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import net from "node:net";

interface BridgeResponse<T = unknown> {
  ok: boolean;
  result?: T;
  error?: string;
}

function bridgePort(): number {
  const raw = process.env.PIOVIM_BRIDGE_PORT;
  const port = raw ? Number.parseInt(raw, 10) : Number.NaN;
  if (!Number.isFinite(port)) {
    throw new Error("PIOVIM_BRIDGE_PORT is not set");
  }
  return port;
}

function bridgeToken(): string {
  const token = process.env.PIOVIM_BRIDGE_TOKEN;
  if (!token) {
    throw new Error("PIOVIM_BRIDGE_TOKEN is not set");
  }
  return token;
}

async function callBridge<T>(method: string, params: unknown, signal?: AbortSignal): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port: bridgePort() });
    let buffer = "";
    let settled = false;

    const cleanup = () => {
      signal?.removeEventListener("abort", onAbort);
      socket.removeAllListeners();
      if (!socket.destroyed) socket.destroy();
    };

    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      cleanup();
      fn();
    };

    const onAbort = () => {
      finish(() => reject(new Error("Neovim bridge request aborted")));
    };

    signal?.addEventListener("abort", onAbort, { once: true });

    socket.on("connect", () => {
      socket.write(JSON.stringify({ token: bridgeToken(), method, params }) + "\n");
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline === -1) return;

      const line = buffer.slice(0, newline);
      let response: BridgeResponse<T>;
      try {
        response = JSON.parse(line) as BridgeResponse<T>;
      } catch {
        finish(() => reject(new Error("Invalid Neovim bridge response")));
        return;
      }

      if (!response.ok) {
        finish(() => reject(new Error(response.error ?? "Neovim bridge request failed")));
        return;
      }

      finish(() => resolve(response.result as T));
    });

    socket.on("error", (error) => {
      finish(() => reject(error));
    });

    socket.on("close", () => {
      if (!settled) {
        finish(() => reject(new Error("Neovim bridge closed before responding")));
      }
    });
  });
}

function jsonText(value: unknown): string {
  return JSON.stringify(value, null, 2);
}

function fenced(language: string | undefined, text: string): string {
  return "```" + (language ?? "") + "\n" + text + "\n```";
}

const bufferTargetSchema = {
  path: Type.Optional(Type.String({ description: "File path for an open Neovim buffer. Omit to use the current/focused code buffer." })),
  bufnr: Type.Optional(Type.Number({ description: "Neovim buffer number. Prefer path unless the tool returned a bufnr." })),
};

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "nvim_get_context",
    label: "Neovim Context",
    description: "Get the current/focused Neovim buffer, cursor, modified state, changedtick, and diagnostic count.",
    promptSnippet: "Get current/focused Neovim buffer metadata and cursor position",
    promptGuidelines: [
      "Use nvim_get_context when the user says current buffer, open buffer, cursor, selection, here, this code, or asks a question from Neovim.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const result = await callBridge("get_context", {}, signal);
      return {
        content: [{ type: "text", text: jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_list_open_buffers",
    label: "Neovim Buffers",
    description: "List open Neovim file buffers with modified state, filetype, changedtick, and diagnostic counts.",
    promptSnippet: "List open Neovim buffers and modified status",
    promptGuidelines: [
      "Use nvim_list_open_buffers before assuming disk state when the user may have unsaved editor buffers open.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const result = await callBridge("list_open_buffers", {}, signal);
      return {
        content: [{ type: "text", text: jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_read_buffer",
    label: "Read Neovim Buffer",
    description: "Read live text from an open Neovim buffer, including unsaved changes. Use this for current/open buffers instead of disk reads when editor state matters.",
    promptSnippet: "Read live unsaved text from an open Neovim buffer",
    promptGuidelines: [
      "Use nvim_read_buffer for the current buffer or any open buffer before using read when unsaved Neovim changes may matter.",
      "Use normal read for unopened files on disk and nvim_read_buffer for live open buffers.",
    ],
    parameters: Type.Object({
      ...bufferTargetSchema,
      start_line: Type.Optional(Type.Number({ description: "1-indexed start line, inclusive." })),
      end_line: Type.Optional(Type.Number({ description: "1-indexed end line, inclusive." })),
      max_bytes: Type.Optional(Type.Number({ description: "Maximum bytes to return. Defaults to 50000." })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge<{
        buffer?: { filetype?: string; path?: string; modified?: boolean; changedtick?: number };
        start_line?: number;
        end_line?: number;
        text?: string;
        truncated?: boolean;
      }>("read_buffer", params, signal);
      const header = [
        `Neovim live buffer: ${result.buffer?.path ?? "current"}`,
        `lines: ${result.start_line ?? "?"}-${result.end_line ?? "?"}`,
        `modified: ${String(result.buffer?.modified ?? false)}`,
        `changedtick: ${String(result.buffer?.changedtick ?? "?")}`,
        result.truncated ? "truncated: true" : undefined,
      ].filter(Boolean).join("\n");
      return {
        content: [{ type: "text", text: header + "\n" + fenced(result.buffer?.filetype, result.text ?? "") }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_get_diagnostics",
    label: "Neovim Diagnostics",
    description: "Get diagnostics for an open Neovim buffer from Neovim's diagnostic API.",
    promptSnippet: "Get live Neovim diagnostics for an open buffer",
    promptGuidelines: [
      "Use nvim_get_diagnostics when explaining errors, warnings, type issues, or why the editor is marking code.",
    ],
    parameters: Type.Object({
      ...bufferTargetSchema,
      max_items: Type.Optional(Type.Number({ description: "Maximum diagnostics to return. Defaults to 100." })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("get_diagnostics", params, signal);
      return {
        content: [{ type: "text", text: jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_open_buffer",
    label: "Open Neovim Buffer",
    description: "Open a file in Neovim and optionally jump to a line/column. Use this to show the user relevant code discovered while explaining a concept.",
    promptSnippet: "Open a file/range in Neovim for the user",
    promptGuidelines: [
      "Use nvim_open_buffer when you find a relevant file or line the user should inspect in Neovim.",
      "Prefer nvim_open_buffer for navigation only; it does not edit or save files.",
    ],
    parameters: Type.Object({
      path: Type.String({ description: "File path to open in Neovim." }),
      line: Type.Optional(Type.Number({ description: "1-indexed line to jump to." })),
      col: Type.Optional(Type.Number({ description: "0-indexed column to jump to." })),
      focus: Type.Optional(Type.Boolean({ description: "Whether to focus the opened editor window. Defaults to true." })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("open_buffer", params, signal);
      return {
        content: [{ type: "text", text: "Opened Neovim buffer.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_highlight_range",
    label: "Highlight Neovim Range",
    description: "Highlight a range in Neovim and optionally add a short label. Use this to visually point at code you are explaining.",
    promptSnippet: "Highlight a code range in Neovim with an optional label",
    promptGuidelines: [
      "Use nvim_highlight_range when explaining code and you want to visually point the user at the exact lines being discussed.",
      "Use append=true when highlighting multiple related ranges; otherwise previous Pi highlights are cleared.",
    ],
    parameters: Type.Object({
      path: Type.String({ description: "File path containing the range." }),
      start_line: Type.Number({ description: "1-indexed start line, inclusive." }),
      end_line: Type.Number({ description: "1-indexed end line, inclusive." }),
      start_col: Type.Optional(Type.Number({ description: "0-indexed start column. Defaults to 0." })),
      end_col: Type.Optional(Type.Number({ description: "0-indexed end column. Defaults to end of line." })),
      label: Type.Optional(Type.String({ description: "Short label shown as virtual text next to the highlighted range." })),
      focus: Type.Optional(Type.Boolean({ description: "Whether to focus the opened editor window. Defaults to true." })),
      append: Type.Optional(Type.Boolean({ description: "Keep existing Pi highlights instead of clearing them first. Defaults to false." })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("highlight_range", params, signal);
      return {
        content: [{ type: "text", text: "Highlighted Neovim range.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_clear_highlights",
    label: "Clear Neovim Highlights",
    description: "Clear ranges highlighted by Pi in Neovim.",
    promptSnippet: "Clear Pi highlights in Neovim",
    promptGuidelines: [
      "Use nvim_clear_highlights when the highlighted ranges are no longer relevant or before starting a new visual explanation.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const result = await callBridge("clear_highlights", {}, signal);
      return {
        content: [{ type: "text", text: "Cleared Neovim Pi highlights." }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_save_buffer",
    label: "Save Neovim Buffer",
    description: "Save a file-backed open Neovim buffer to disk. Does not edit the buffer. Refuses non-file buffers.",
    promptSnippet: "Save an open file-backed Neovim buffer",
    promptGuidelines: [
      "Use nvim_save_buffer when the user asks to save an open/current Neovim buffer after reviewing or editing it.",
      "Include expected_changedtick when available from nvim_read_buffer or nvim_get_context.",
      "Do not use this for Pi chat, terminal, dashboard, help, scratch, or other non-file-backed buffers.",
    ],
    parameters: Type.Object({
      ...bufferTargetSchema,
      expected_changedtick: Type.Optional(Type.Number({ description: "changedtick from nvim_read_buffer/nvim_get_context. If supplied, save fails when buffer changed." })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("save_buffer", params, signal);
      return {
        content: [{ type: "text", text: "Saved Neovim buffer.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_close_buffer",
    label: "Close Neovim Buffer",
    description: "Close an open Neovim buffer only when it has no unsaved changes. Refuses modified buffers and never discards changes.",
    promptSnippet: "Close an unmodified open Neovim buffer",
    promptGuidelines: [
      "Use nvim_close_buffer only when the user asks to close an open/current buffer.",
      "This tool refuses modified buffers. If it reports unsaved changes, ask the user whether to save, cancel, or discard; do not retry automatically.",
      "Do not use this for Pi chat or prompt buffers.",
    ],
    parameters: Type.Object({
      ...bufferTargetSchema,
      expected_changedtick: Type.Optional(Type.Number({ description: "changedtick from nvim_read_buffer/nvim_get_context. If supplied, close fails when buffer changed." })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("close_buffer", params, signal);
      return {
        content: [{ type: "text", text: "Closed Neovim buffer.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_edit_buffer",
    label: "Edit Neovim Buffer",
    description: "Apply exact text replacements or explicit range edits to an open Neovim buffer after showing an in-place diff preview. Edits are unsaved and undoable in Neovim. Does not write to disk.",
    promptSnippet: "Preview and apply exact or range-based unsaved edits to an open Neovim buffer",
    promptGuidelines: [
      "Use nvim_edit_buffer only when the user asks to change an open/current Neovim buffer and unsaved undoable editor edits are desired.",
      "Before nvim_edit_buffer, read the target with nvim_read_buffer and include expected_changedtick when available.",
      "Use edits with oldText/newText when oldText is non-empty and matches exactly once in the live buffer.",
      "Use rangeEdits for insertions, empty buffers, replacing a known line/column range, or when oldText would be empty/ambiguous.",
      "For an empty buffer insertion, use rangeEdits with startLine=1,startCol=0,endLine=1,endCol=0.",
      "Use normal edit/write for unopened files, repo-wide disk edits, or when the user asks to write files on disk.",
    ],
    parameters: Type.Object({
      ...bufferTargetSchema,
      expected_changedtick: Type.Optional(Type.Number({ description: "changedtick from nvim_read_buffer/nvim_get_context. If supplied, edit fails when buffer changed." })),
      edits: Type.Optional(Type.Array(Type.Object({
        oldText: Type.String({ description: "Exact non-empty text to replace. Must match exactly once in the live Neovim buffer. Use rangeEdits for insertion or empty buffers." }),
        newText: Type.String({ description: "Replacement text." }),
      }))),
      rangeEdits: Type.Optional(Type.Array(Type.Object({
        startLine: Type.Number({ description: "1-indexed start line, inclusive." }),
        startCol: Type.Number({ description: "0-indexed start column, inclusive." }),
        endLine: Type.Number({ description: "1-indexed end line, inclusive." }),
        endCol: Type.Number({ description: "0-indexed end column, exclusive." }),
        newText: Type.String({ description: "Replacement text for the range. For insertion, start and end positions are the same." }),
      }))),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("edit_buffer", params, signal);
      return {
        content: [{ type: "text", text: "Applied previewed unsaved Neovim buffer edit. File was not written to disk.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_get_review_diff",
    label: "Get Review Diff",
    description: "Get the active Pi review diff context, including comparison, changed files, current hunk, and review annotations.",
    promptSnippet: "Get active Pi review diff context and annotations",
    promptGuidelines: [
      "Use nvim_get_review_diff when the user asks about the current review diff, current hunk, diff annotations, or wants help fixing review notes.",
      "This tool reads Piovim's review diff UI state; use it instead of shelling out to git when the user is collaborating in the diff viewer.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const result = await callBridge("get_review_diff", {}, signal);
      return {
        content: [{ type: "text", text: "Active Pi review diff:\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_add_review_annotation",
    label: "Add Review Annotation",
    description: "Add an annotation to the active Pi review diff. Omit range to annotate the current diff line.",
    promptSnippet: "Add an annotation to the active Pi review diff",
    promptGuidelines: [
      "Use nvim_add_review_annotation when the user asks you to leave a review note on the current diff line or a specific diff range.",
      "Prefer concise actionable notes that can be surfaced in the quickfix list and fixed later.",
    ],
    parameters: Type.Object({
      note: Type.String({ description: "Review note text." }),
      range: Type.Optional(Type.Object({
        path: Type.String({ description: "Repo-relative file path in the diff." }),
        line: Type.Number({ description: "1-indexed source line to anchor the note to." }),
        end_line: Type.Optional(Type.Number({ description: "Optional 1-indexed end line for multi-line annotations." })),
        old_line: Type.Optional(Type.Number({ description: "Old-side line number when applicable." })),
        new_line: Type.Optional(Type.Number({ description: "New-side line number when applicable." })),
        text: Type.Optional(Type.String({ description: "Diff line text being annotated." })),
      })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("add_review_annotation", params, signal);
      return {
        content: [{ type: "text", text: "Added Pi review annotation.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_refresh_review_diff",
    label: "Refresh Review Diff",
    description: "Refresh the active Pi review diff from Git, disk, and live Neovim buffers.",
    promptSnippet: "Refresh the active Pi review diff",
    promptGuidelines: [
      "Use nvim_refresh_review_diff after editing files referenced by the active review diff, especially after disk edits or completing review-note fixes.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const result = await callBridge("refresh_review_diff", {}, signal);
      return {
        content: [{ type: "text", text: "Refreshed Pi review diff.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "nvim_resolve_review_annotation",
    label: "Resolve Review Annotation",
    description: "Resolve/remove a review annotation from the active Pi review diff after fixing it.",
    promptSnippet: "Resolve/remove a Pi review annotation",
    promptGuidelines: [
      "Use nvim_resolve_review_annotation after you have fixed a specific active review annotation.",
      "Prefer resolving by annotation id from nvim_get_review_diff. If no id is available, resolve by path and line.",
    ],
    parameters: Type.Object({
      id: Type.Optional(Type.Number({ description: "Annotation id from nvim_get_review_diff." })),
      path: Type.Optional(Type.String({ description: "Repo-relative file path for location-based resolution." })),
      line: Type.Optional(Type.Number({ description: "1-indexed source line for location-based resolution." })),
    }),
    async execute(_toolCallId, params, signal) {
      const result = await callBridge("resolve_review_annotation", params, signal);
      return {
        content: [{ type: "text", text: "Resolved Pi review annotation.\n" + jsonText(result) }],
        details: result,
      };
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setWidget("piovim:startup", [
      "nvim_get_context, nvim_list_open_buffers, nvim_read_buffer, nvim_get_diagnostics, nvim_open_buffer, nvim_highlight_range, nvim_clear_highlights, nvim_save_buffer, nvim_close_buffer, nvim_edit_buffer, nvim_get_review_diff, nvim_add_review_annotation, nvim_refresh_review_diff, nvim_resolve_review_annotation",
      "Open buffers are live Neovim state; nvim_edit_buffer applies unsaved undoable edits. Pi review diff tools expose the active diff, hunk, and annotations.",
    ]);
  });
}
