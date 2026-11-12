// The fixed command set. Must match RemoteCommand.swift on the Mac, which validates again.
// There is intentionally no command that runs arbitrary shell or code.

export type Args = Record<string, unknown>;

const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/;

const isPid = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v > 1 && v < 2 ** 31;
const isBool = (v: unknown) => typeof v === "boolean";
const isBundleId = (v: unknown) => typeof v === "string" && BUNDLE_ID.test(v);

type Spec = Record<string, (v: unknown) => boolean>;

const SPECS: Record<string, Spec> = {
  refresh: {},
  listInstalledApps: {},
  quitApp: { pid: isPid },
  forceQuitApp: { pid: isPid },
  pauseApp: { pid: isPid },
  resumeApp: { pid: isPid },
  launchApp: { bundleId: isBundleId },
  setLidMode: { enabled: isBool },
  setAllowList: {
    bundleIds: (v) => Array.isArray(v) && v.length <= 500 && v.every(isBundleId),
  },
  setQuitInsteadOfPause: { bundleId: isBundleId, enabled: isBool },
};

export function validateCommand(cmd: unknown, args: unknown): { cmd: string; args: Args } | string {
  if (typeof cmd !== "string" || !Object.hasOwn(SPECS, cmd)) return "unknown command";
  const a = (args ?? {}) as Args;
  if (typeof a !== "object" || Array.isArray(a)) return "args must be an object";
  const spec = SPECS[cmd];
  const want = Object.keys(spec).sort();
  const got = Object.keys(a).sort();
  if (want.join(",") !== got.join(",")) return `expected args: ${want.join(", ") || "(none)"}`;
  for (const k of want) if (!spec[k](a[k])) return `invalid ${k}`;
  return { cmd, args: a };
}
