/** A connection to an existing Codex daemon. Closing it never stops the daemon. */
export interface CodexSocket {
  request(method: string, params?: unknown): Promise<any>;
  write(message: unknown): void;
  close(): void;
  isOpen(): boolean;
}

export async function connectCodexSocket(
  path: string,
  notification: (message: any) => void,
  disconnected: () => void,
  timeout = 30_000,
): Promise<CodexSocket> {
  if (!path.startsWith("/") || /[\0:?#]/.test(path)) throw new Error("Expected an absolute Codex socket path");
  const socket = new WebSocket(`ws+unix://${path}:/`);
  let nextId = 1;
  const pending = new Map<number, { resolve(value: any): void; reject(error: Error): void }>();
  let closed = false;
  const finish = () => {
    if (closed) return;
    closed = true;
    for (const request of pending.values()) request.reject(new Error("Codex connection closed"));
    pending.clear();
    disconnected();
  };
  socket.addEventListener("close", finish);
  socket.addEventListener("message", ({ data }) => {
    let message;
    try { message = JSON.parse(String(data)); } catch { return; }
    if (!message || typeof message !== "object" || Array.isArray(message)) return;
    if (message.id != null && ("result" in message || "error" in message)) {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message ?? "Codex RPC error"));
      else request.resolve(message.result);
    } else notification(message);
  });
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => { socket.close(); reject(new Error("Codex connection timed out")); }, timeout);
    socket.addEventListener("open", () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener("error", () => { clearTimeout(timer); socket.close(); reject(new Error("Cannot connect to the existing Codex daemon")); }, { once: true });
    socket.addEventListener("close", () => { clearTimeout(timer); reject(new Error("Codex connection closed before opening")); }, { once: true });
  });
  const write = (message: unknown) => {
    if (socket.readyState !== WebSocket.OPEN) throw new Error("Codex connection is closed");
    socket.send(JSON.stringify(message));
  };
  return {
    write,
    isOpen: () => socket.readyState === WebSocket.OPEN,
    close: () => { finish(); socket.close(); },
    request: (method, params = {}) => new Promise((resolve, reject) => {
      const id = nextId++;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Codex ${method} timed out`)); }, timeout);
      pending.set(id, {
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); },
      });
      try { write({ id, method, params }); }
      catch (error) { pending.delete(id); clearTimeout(timer); reject(error); }
    }),
  };
}
