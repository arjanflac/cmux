/** Personal GUI preference only; never changes a provider's CLI configuration. */
export function graphicalFullAccessDefault(environment = process.env): boolean {
  return environment.CMUX_AGENT_CHAT_FULL_ACCESS_DEFAULT === "1";
}
