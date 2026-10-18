import type { Provider } from "@earendil-works/pi-ai";
import type { normalizeContext } from "@earendil-works/pi-ai";
import type { AccountUsage } from "./types.js";

export type {
  OAuthCredential,
  ProviderAuthInteraction,
} from "@earendil-works/pi-ai";
export type AccountSDK = {
  providers: readonly Provider[];
  normalizeContext: typeof normalizeContext;
};
export type HostQuotaAccount = Omit<AccountUsage, "accountName"> & {
  name: string;
  hidden: boolean;
};
export type HostQuotaSnapshot = {
  version: number;
  provider: string;
  accounts: HostQuotaAccount[];
  updatedAt: number;
  gemini: unknown;
  source: string;
  cached?: boolean;
};
