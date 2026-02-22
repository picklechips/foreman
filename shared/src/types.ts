import { z } from "zod";

// ─── Session ──────────────────────────────────────────────────────────────────

export const SessionStatusSchema = z.enum([
  "idle",
  "thinking",
  "waiting_input",
  "error",
  "dead",
]);
export type SessionStatus = z.infer<typeof SessionStatusSchema>;

export const SessionSchema = z.object({
  id: z.string().uuid(),
  name: z.string().regex(/^[a-zA-Z0-9-]{1,32}$/),
  cwd: z.string(),
  model: z.string(),
  status: SessionStatusSchema,
  createdAt: z.string().datetime(),
  lastActiveAt: z.string().datetime(),
});
export type Session = z.infer<typeof SessionSchema>;

// ─── Claude Events (server → client, pushed) ─────────────────────────────────

export const AssistantTextEventSchema = z.object({
  type: z.literal("assistant_text"),
  text: z.string(),
});

export const ThinkingEventSchema = z.object({
  type: z.literal("thinking"),
  text: z.string(),
});

export const ToolUseEventSchema = z.object({
  type: z.literal("tool_use"),
  tool: z.string(),
  input: z.record(z.unknown()),
});

export const ToolResultEventSchema = z.object({
  type: z.literal("tool_result"),
  tool: z.string(),
  ok: z.boolean(),
  summary: z.string(), // truncated to 200 chars
});

export const StopEventSchema = z.object({
  type: z.literal("stop"),
  reason: z.enum(["end_turn", "interrupted", "error"]),
});

export const WaitingInputEventSchema = z.object({
  type: z.literal("waiting_input"),
  message: z.string(),
});

export const SessionStatusEventSchema = z.object({
  type: z.literal("session_status"),
  status: SessionStatusSchema,
});

export const ClaudeEventSchema = z.discriminatedUnion("type", [
  AssistantTextEventSchema,
  ThinkingEventSchema,
  ToolUseEventSchema,
  ToolResultEventSchema,
  StopEventSchema,
  WaitingInputEventSchema,
  SessionStatusEventSchema,
]);
export type ClaudeEvent = z.infer<typeof ClaudeEventSchema>;

// ─── Server → Client messages ─────────────────────────────────────────────────

export const ServerEventMessageSchema = z.object({
  type: z.literal("event"),
  sessionId: z.string().uuid(),
  event: ClaudeEventSchema,
});

export const ServerResponseSchema = z.object({
  type: z.literal("response"),
  id: z.string(),
  ok: z.boolean(),
  result: z.unknown().optional(),
  error: z.string().optional(),
});

export const ServerMessageSchema = z.discriminatedUnion("type", [
  ServerEventMessageSchema,
  ServerResponseSchema,
]);
export type ServerMessage = z.infer<typeof ServerMessageSchema>;
export type ServerResponse = z.infer<typeof ServerResponseSchema>;

// ─── Client → Server messages ─────────────────────────────────────────────────

export const AuthMessageSchema = z.object({
  type: z.literal("auth"),
  token: z.string(),
});

export const SessionListRequestSchema = z.object({
  type: z.literal("session.list"),
  id: z.string(),
});

export const SessionCreateRequestSchema = z.object({
  type: z.literal("session.create"),
  id: z.string(),
  name: z.string().regex(/^[a-zA-Z0-9-]{1,32}$/, "Name must be alphanumeric/hyphen, max 32 chars"),
  cwd: z.string().min(1),
  model: z.string().optional(),
});

export const SessionMessageRequestSchema = z.object({
  type: z.literal("session.message"),
  id: z.string(),
  sessionId: z.string().uuid(),
  text: z.string().min(1).max(32000),
});

export const SessionInterruptRequestSchema = z.object({
  type: z.literal("session.interrupt"),
  id: z.string(),
  sessionId: z.string().uuid(),
});

export const SessionDestroyRequestSchema = z.object({
  type: z.literal("session.destroy"),
  id: z.string(),
  sessionId: z.string().uuid(),
});

export const SessionHistoryRequestSchema = z.object({
  type: z.literal("session.history"),
  id: z.string(),
  sessionId: z.string().uuid(),
  limit: z.number().int().min(1).max(500).default(100),
});

export const ClientRequestSchema = z.discriminatedUnion("type", [
  SessionListRequestSchema,
  SessionCreateRequestSchema,
  SessionMessageRequestSchema,
  SessionInterruptRequestSchema,
  SessionDestroyRequestSchema,
  SessionHistoryRequestSchema,
]);
export type ClientRequest = z.infer<typeof ClientRequestSchema>;

// Full union of everything a client can send (auth handshake + requests).
// Relay uses this as its single parse point for all incoming messages.
export const ClientMessageSchema = z.discriminatedUnion("type", [
  AuthMessageSchema,
  SessionListRequestSchema,
  SessionCreateRequestSchema,
  SessionMessageRequestSchema,
  SessionInterruptRequestSchema,
  SessionDestroyRequestSchema,
  SessionHistoryRequestSchema,
]);
export type ClientMessage = z.infer<typeof ClientMessageSchema>;

// ─── Transcript ───────────────────────────────────────────────────────────────

export const TranscriptEntrySchema = z.object({
  id: z.string().uuid(),
  role: z.enum(["user", "assistant", "tool"]),
  content: z.string(),
  timestamp: z.string().datetime(),
  toolCall: z
    .object({ tool: z.string(), input: z.record(z.unknown()) })
    .optional(),
  toolResult: z
    .object({ tool: z.string(), ok: z.boolean(), summary: z.string() })
    .optional(),
});
export type TranscriptEntry = z.infer<typeof TranscriptEntrySchema>;

// ─── Relay config ─────────────────────────────────────────────────────────────

export const RelayConfigSchema = z.object({
  port: z.number().int().min(1024).max(65535).default(7821),
  hooksPort: z.number().int().min(1024).max(65535).default(7822),
  bindHost: z.string().default("127.0.0.1"),
  allowedDirs: z.array(z.string()).min(1),
  model: z.string().default("claude-opus-4-6"),
  ntfyTopic: z.string().default(""),
});
export type RelayConfig = z.infer<typeof RelayConfigSchema>;
