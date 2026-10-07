export class APIError extends Error {
  status: number;
  uncertain: boolean;
  /** Seconds a rate-limited caller should wait; absent otherwise. */
  retryAfter?: number;
  constructor(
    message: string,
    status = 0,
    uncertain = false,
    retryAfter?: number,
  ) {
    super(message);
    this.status = status;
    this.uncertain = uncertain;
    this.retryAfter = retryAfter;
  }
}
/**
 * Explains a rate-limit refusal. DANS refuses these before authorization or
 * forwarding, so the request was not applied; the console never retries.
 */
function rateLimitError(
  response: Response,
  errors: string[],
): APIError | undefined {
  const buckets = response.headers.get("X-DANS-RateLimit-Bucket");
  if (!buckets) return undefined;
  if (response.status === 429) {
    const seconds = Number.parseInt(
      response.headers.get("Retry-After") ?? "",
      10,
    );
    const wait =
      seconds > 0
        ? `Wait ${seconds} second${seconds === 1 ? "" : "s"} before trying again.`
        : "Wait before trying again.";
    return new APIError(
      `Rate limit reached (${buckets}). This request was not applied. ${wait}`,
      429,
      false,
      seconds > 0 ? seconds : undefined,
    );
  }
  if (response.status === 413) {
    const value = (name: string) =>
      errors.find((entry) => entry.startsWith(name + ": "))?.slice(name.length + 2);
    const cost = value("cost"),
      capacity = value("capacity");
    const sizes =
      cost && capacity ? ` (cost ${cost}, capacity ${capacity})` : "";
    return new APIError(
      `This request exceeds your ${buckets} rate-limit capacity${sizes} and was not applied. Split it into smaller changes or ask an operator to raise your limit.`,
      413,
    );
  }
  return undefined;
}
export async function request<T>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const mutation = !["GET", "HEAD"].includes(init.method ?? "GET");
  let response: Response;
  try {
    response = await fetch("/api/v1" + path, {
      ...init,
      credentials: "same-origin",
      redirect: "error",
      cache: "no-store",
      headers: {
        Accept: "application/json",
        ...(init.body ? { "Content-Type": "application/json" } : {}),
        ...init.headers,
      },
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError")
      throw error;
    throw new APIError(
      mutation
        ? "Outcome unknown. Read the current state before deciding what to do next. This request was not retried."
        : "Could not reach the API. Try loading again.",
      0,
      mutation,
    );
  }
  if (!response.ok) {
    let detail = response.statusText;
    let errors: string[] = [];
    try {
      const body = await response.json();
      errors = Array.isArray(body.errors) ? body.errors : [];
      detail = [body.error, ...errors].filter(Boolean).join(" — ") || detail;
    } catch {
      /* The status still identifies an unsuccessful response. */
    }
    const limited = rateLimitError(response, errors);
    if (limited) throw limited;
    const uncertain =
      mutation && (response.status >= 500 || response.status === 408);
    if (
      response.status === 401 &&
      path !== "/dans/session" &&
      typeof window !== "undefined"
    )
      window.dispatchEvent(new Event("console:unauthorized"));
    throw new APIError(
      uncertain
        ? "Outcome unknown. Read the current state before another write. This request was not retried."
        : detail,
      response.status,
      uncertain,
    );
  }
  if (response.status === 204) return undefined as T;
  try {
    return (await response.json()) as T;
  } catch {
    // A received successful mutation status is conclusive even if its optional body is incomplete.
    if (mutation) return undefined as T;
    throw new APIError(
      "The API response was incomplete. Try loading again.",
      response.status,
    );
  }
}
export const zonePath = (id: string) =>
  "/servers/localhost/zones/" + encodeURIComponent(id);
export const browsePath = (id: string) =>
  "/dans/servers/localhost/zones/" + encodeURIComponent(id) + "/rrsets";
