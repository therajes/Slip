import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { open as openFileDialog } from "@tauri-apps/plugin-dialog";
import { disable, enable, isEnabled } from "@tauri-apps/plugin-autostart";
import { toast } from "sonner";
import { FaBoxOpen, FaClockRotateLeft, FaMobileScreenButton, FaShield } from "react-icons/fa6";
import { DeviceInfo } from "../Device";
import { useStore } from "../StoreContext";
import { Modal } from "./Modal";
import { customSideloadOperation, Operation } from "./operations";
import "./IpaWorkbench.css";

type IpaExtensionInfo = {
  path: string;
  bundleId: string;
  name: string;
  extensionPoint?: string;
};

type IpaInfo = {
  path: string;
  fileName: string;
  appName: string;
  bundleId: string;
  version: string;
  buildVersion: string;
  minimumOsVersion?: string;
  executable?: string;
  sizeBytes: number;
  extensions: IpaExtensionInfo[];
  appIdCost: number;
  warnings: string[];
};

type InstallOptions = {
  appPath: string;
  displayName?: string;
  bundleId?: string;
  removedExtensions: string[];
  customIconPath?: string;
  increasedMemoryLimit: boolean;
};

type SavedIpaProfile = {
  id: string;
  appName: string;
  bundleId: string;
  deviceUdid: string;
  deviceName: string;
  accountEmail: string;
  autoRefresh: boolean;
  installedAt: string;
  expiresAt: string;
  options: InstallOptions;
};

type StartOperation = (
  operation: Operation,
  params: Record<string, unknown>,
) => Promise<void>;

const humanSize = (bytes: number) => {
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit > 1 ? 1 : 0)} ${units[unit]}`;
};

const extensionDescription = (point?: string) => {
  if (!point) return "Embedded app extension";
  if (point.includes("widget")) return "Widget or Live Activity";
  if (point.includes("share")) return "Share sheet integration";
  if (point.includes("usernotifications")) return "Notification processing";
  if (point.includes("keyboard")) return "Custom keyboard";
  if (point.includes("intent")) return "Siri or Shortcuts intent";
  return point;
};

export function IpaWorkbench({
  selectedDevice,
  loggedInAs,
  canInstall,
  startOperation,
}: {
  selectedDevice: DeviceInfo | null;
  loggedInAs: string | null;
  canInstall: () => boolean;
  startOperation: StartOperation;
}) {
  const [info, setInfo] = useState<IpaInfo | null>(null);
  const [inspecting, setInspecting] = useState(false);
  const [displayName, setDisplayName] = useState("");
  const [bundleId, setBundleId] = useState("");
  const [customIconPath, setCustomIconPath] = useState<string | undefined>();
  const [removedExtensions, setRemovedExtensions] = useState<Set<string>>(new Set());
  const [rememberProfile, setRememberProfile] = useState(true);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [increasedMemoryLimit, setIncreasedMemoryLimit] = useState(false);
  const [savedProfiles, setSavedProfiles] = useStore<SavedIpaProfile[]>(
    "savedIpaProfiles",
    [],
  );
  const [refreshGuardEnabled, setRefreshGuardEnabled] = useStore(
    "refreshGuardEnabled",
    true,
  );
  const [lastAutoRefreshAttempts, setLastAutoRefreshAttempts] = useState<Record<string, number>>({});

  useEffect(() => {
    const configureAutostart = async () => {
      const shouldStart = refreshGuardEnabled && savedProfiles.some((profile) => profile.autoRefresh);
      const currentlyEnabled = await isEnabled();
      if (shouldStart && !currentlyEnabled) await enable();
      if (!shouldStart && currentlyEnabled) await disable();
    };
    void configureAutostart().catch((error) => {
      console.error("Unable to configure Refresh Guard autostart", error);
    });
  }, [refreshGuardEnabled, savedProfiles]);

  const loadIpa = useCallback(async (path: string) => {
    setInspecting(true);
    try {
      const result = await invoke<IpaInfo>("inspect_ipa", { appPath: path });
      setInfo(result);
      setDisplayName(result.appName);
      setBundleId(result.bundleId);
      setCustomIconPath(undefined);
      // The free-account friendly default: keep the main app, remove extensions.
      setRemovedExtensions(new Set(result.extensions.map((extension) => extension.path)));
    } catch (error) {
      toast.error(`Unable to inspect IPA: ${String((error as { message?: string })?.message ?? error)}`);
    } finally {
      setInspecting(false);
    }
  }, []);

  const chooseIpa = useCallback(async () => {
    const path = await openFileDialog({
      multiple: false,
      filters: [{ name: "IPA Files", extensions: ["ipa"] }],
    });
    if (typeof path === "string") await loadIpa(path);
  }, [loadIpa]);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    getCurrentWebviewWindow()
      .onDragDropEvent((event) => {
        if (event.payload.type !== "drop") return;
        const ipa = event.payload.paths.find((path) => path.toLowerCase().endsWith(".ipa"));
        if (ipa) void loadIpa(ipa);
      })
      .then((fn) => {
        unlisten = fn;
      });
    return () => unlisten?.();
  }, [loadIpa]);

  const appIdCost = useMemo(
    () => 1 + (info?.extensions.length ?? 0) - removedExtensions.size,
    [info, removedExtensions],
  );

  const buildOptions = useCallback(
    (): InstallOptions | null => {
      if (!info) return null;
      return {
        appPath: info.path,
        displayName: displayName.trim() || info.appName,
        bundleId: bundleId.trim() || info.bundleId,
        removedExtensions: [...removedExtensions],
        customIconPath,
        increasedMemoryLimit,
      };
    }, [bundleId, customIconPath, displayName, increasedMemoryLimit, info, removedExtensions],
  );

  const install = useCallback(async () => {
    if (!info) {
      toast.error("Choose an IPA before installing.");
      return;
    }
    if (!loggedInAs) {
      toast.error("Sign in under Account & access before installing this app.");
      return;
    }
    if (!selectedDevice) {
      toast.error("Select an iPhone before installing this app.");
      return;
    }
    if (!canInstall()) return;
    const options = buildOptions();
    if (!options) return;
    try {
      await startOperation(customSideloadOperation, { options });
      if (rememberProfile) {
        const installedAt = new Date();
        const expiresAt = new Date(installedAt.getTime() + 7 * 24 * 60 * 60 * 1000);
        const id = `${selectedDevice.udid}:${options.bundleId}`;
        const profile: SavedIpaProfile = {
          id,
          appName: options.displayName || info.appName,
          bundleId: options.bundleId || info.bundleId,
          deviceUdid: selectedDevice.udid,
          deviceName: selectedDevice.name,
          accountEmail: loggedInAs,
          autoRefresh,
          installedAt: installedAt.toISOString(),
          expiresAt: expiresAt.toISOString(),
          options,
        };
        setSavedProfiles((profiles) => [profile, ...profiles.filter((item) => item.id !== id)]);
      }
      setInfo(null);
    } catch {
      // OperationView owns the detailed error presentation.
    }
  }, [autoRefresh, buildOptions, canInstall, info, loggedInAs, rememberProfile, selectedDevice, setSavedProfiles, startOperation]);

  const refreshProfile = useCallback(
    async (profile: SavedIpaProfile) => {
      if (!selectedDevice || selectedDevice.udid !== profile.deviceUdid) {
        toast.error(`Select ${profile.deviceName} before refreshing this app.`);
        return;
      }
      if (!canInstall()) return;
      try {
        await startOperation(customSideloadOperation, { options: profile.options });
        const installedAt = new Date();
        const expiresAt = new Date(installedAt.getTime() + 7 * 24 * 60 * 60 * 1000);
        setSavedProfiles((profiles) =>
          profiles.map((item) =>
            item.id === profile.id
              ? { ...item, installedAt: installedAt.toISOString(), expiresAt: expiresAt.toISOString() }
              : item,
          ),
        );
      } catch {
        // OperationView owns the detailed error presentation.
      }
    },
    [canInstall, selectedDevice, setSavedProfiles, startOperation],
  );

  useEffect(() => {
    if (!refreshGuardEnabled || !selectedDevice || !loggedInAs) return;

    const check = () => {
      const now = Date.now();
      const refreshWindow = 48 * 60 * 60 * 1000;
      const retryWindow = 6 * 60 * 60 * 1000;
      const due = savedProfiles.find((profile) => {
        const lastAttempt = lastAutoRefreshAttempts[profile.id] ?? 0;
        return profile.autoRefresh
          && profile.deviceUdid === selectedDevice.udid
          && profile.accountEmail === loggedInAs
          && new Date(profile.expiresAt).getTime() - now <= refreshWindow
          && now - lastAttempt >= retryWindow;
      });
      if (!due) return;
      setLastAutoRefreshAttempts((attempts) => ({ ...attempts, [due.id]: now }));
      void refreshProfile(due);
    };

    const initial = window.setTimeout(check, 15_000);
    const interval = window.setInterval(check, 5 * 60 * 1000);
    return () => {
      window.clearTimeout(initial);
      window.clearInterval(interval);
    };
  }, [lastAutoRefreshAttempts, loggedInAs, refreshGuardEnabled, refreshProfile, savedProfiles, selectedDevice]);

  return (
    <>
      <div className="ipa-drop-shell">
        <button className="ipa-dropzone" onClick={chooseIpa} disabled={inspecting}>
          <span className="ipa-drop-icon"><FaBoxOpen /></span>
          <span>
            <strong>{inspecting ? "Reading package…" : "Choose an IPA"}</strong>
            <small>Click or drop anywhere in this window</small>
          </span>
          <span className="choose-file-cue">Choose…</span>
        </button>
        <div className="ipa-flow" aria-label="Installation workflow">
          <span><b>01</b> Inspect</span><i />
          <span><b>02</b> Tailor</span><i />
          <span><b>03</b> Sign</span><i />
          <span><b>04</b> Deliver</span>
        </div>
      </div>

      {savedProfiles.length > 0 && (
        <div className="refresh-library">
          <div className="refresh-library-heading">
            <span><FaClockRotateLeft /> Refresh library</span>
            <small>Private, local profiles</small>
          </div>
          {savedProfiles.slice(0, 3).map((profile) => {
            const remainingMs = new Date(profile.expiresAt).getTime() - Date.now();
            const remainingDays = Math.max(0, Math.ceil(remainingMs / 86_400_000));
            return (
              <div className="refresh-profile" key={profile.id}>
                <div>
                  <strong>{profile.appName}</strong>
                  <small>{profile.deviceName} · {remainingDays} day{remainingDays === 1 ? "" : "s"} left{profile.autoRefresh ? " · Guard on" : ""}</small>
                </div>
                <div className="refresh-profile-actions">
                  <button onClick={() => void refreshProfile(profile)}>Refresh</button>
                  <button
                    className="quiet-button"
                    aria-label={`Forget ${profile.appName}`}
                    onClick={() => setSavedProfiles((items) => items.filter((item) => item.id !== profile.id))}
                  >
                    Forget
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      <Modal isOpen={info !== null} close={() => setInfo(null)}>
        {info && (
          <div className="ipa-workbench">
            <div className="ipa-workbench-header">
              <div className="ipa-app-mark"><FaMobileScreenButton /></div>
              <div>
                <p className="eyebrow">IPA Workbench</p>
                <h2>{info.appName}</h2>
                <p>{info.fileName} · {humanSize(info.sizeBytes)}</p>
              </div>
              <div className={`id-cost ${appIdCost > 3 ? "warning" : ""}`}>
                <span>{appIdCost}</span>
                <small>App ID{appIdCost === 1 ? "" : "s"}</small>
              </div>
            </div>

            <div className="ipa-facts">
              <span>Version {info.version} ({info.buildVersion})</span>
              <span>Minimum iOS {info.minimumOsVersion ?? "not declared"}</span>
              <span>{info.extensions.length} extension{info.extensions.length === 1 ? "" : "s"}</span>
            </div>

            {info.warnings.map((warning) => <div className="ipa-warning" key={warning}>{warning}</div>)}

            <div className="ipa-editor-grid">
              <section className="ipa-editor-section">
                <div className="editor-heading">
                  <div><h3>Identity</h3><p>Customize what appears on your Home Screen.</p></div>
                </div>
                <label>
                  App name
                  <input value={displayName} maxLength={30} onChange={(event) => setDisplayName(event.target.value)} />
                </label>
                <label>
                  Bundle ID
                  <input value={bundleId} spellCheck={false} onChange={(event) => setBundleId(event.target.value)} />
                </label>
                <div className="icon-picker">
                  <div><strong>Custom icon</strong><small>{customIconPath?.split("/").pop() ?? "Use the icon included in the IPA"}</small></div>
                  <button onClick={async () => {
                    const path = await openFileDialog({ multiple: false, filters: [{ name: "Images", extensions: ["png", "jpg", "jpeg", "webp"] }] });
                    if (typeof path === "string") setCustomIconPath(path);
                  }}>Choose…</button>
                </div>
              </section>

              <section className="ipa-editor-section">
                <div className="editor-heading extension-heading">
                  <div><h3>Extensions</h3><p>Removed by default to conserve free App IDs.</p></div>
                  {info.extensions.length > 0 && (
                    <button className="quiet-button" onClick={() => setRemovedExtensions((current) => current.size ? new Set() : new Set(info.extensions.map((item) => item.path)))}>
                      {removedExtensions.size ? "Keep all" : "Remove all"}
                    </button>
                  )}
                </div>
                {info.extensions.length === 0 ? (
                  <div className="empty-extensions"><FaShield /> No embedded extensions</div>
                ) : info.extensions.map((extension) => {
                  const kept = !removedExtensions.has(extension.path);
                  return (
                    <label className="extension-row" key={extension.path}>
                      <input type="checkbox" checked={kept} onChange={() => setRemovedExtensions((current) => {
                        const next = new Set(current);
                        if (kept) next.add(extension.path); else next.delete(extension.path);
                        return next;
                      })} />
                      <span><strong>{extension.name}</strong><small>{extensionDescription(extension.extensionPoint)} · {extension.bundleId}</small></span>
                    </label>
                  );
                })}
              </section>
            </div>

            <div className="advanced-options">
              <label><input type="checkbox" checked={increasedMemoryLimit} onChange={(event) => setIncreasedMemoryLimit(event.target.checked)} /> Request increased memory entitlement</label>
              <label><input type="checkbox" checked={rememberProfile} onChange={(event) => setRememberProfile(event.target.checked)} /> Remember this setup for one-click refresh</label>
              <label><input type="checkbox" checked={autoRefresh} disabled={!rememberProfile} onChange={(event) => setAutoRefresh(event.target.checked)} /> Auto-refresh about 48 hours before expiry</label>
              <label><input type="checkbox" checked={refreshGuardEnabled} onChange={(event) => setRefreshGuardEnabled(event.target.checked)} /> Launch Refresh Guard at Mac login</label>
            </div>

            <div className="ipa-install-footer">
              <div><strong>Ready to prepare, sign, and stream to {selectedDevice?.name ?? "your iPhone"}</strong><small>Credentials and IPA contents remain on this Mac.</small></div>
              <button className="primary-button" onClick={() => void install()}>
                {!loggedInAs ? "Sign in required" : !selectedDevice ? "Select iPhone" : "Install app"}
              </button>
            </div>
          </div>
        )}
      </Modal>
    </>
  );
}
