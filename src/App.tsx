import { useCallback, useEffect, useRef, useState } from "react";
import "./App.css";
import { AppleID } from "./AppleID";
import { Device, DeviceInfo } from "./Device";
import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  Operation,
  OperationState,
  OperationUpdate,
} from "./components/operations";
import { listen } from "@tauri-apps/api/event";
import OperationView from "./components/OperationView";
import { toast } from "sonner";
import { Modal } from "./components/Modal";
import { Certificates } from "./pages/Certificates";
import { AppIds } from "./pages/AppIds";
import { Settings } from "./pages/Settings";
import { Pairing } from "./pages/Pairing";
import { getVersion } from "@tauri-apps/api/app";
import logo from "./assets/sideloom-icon.png";
import { GlassCard } from "./components/GlassCard";
import { useTranslation } from "react-i18next";
import { usePlatform } from "./PlatformContext";
import { IpaWorkbench } from "./components/IpaWorkbench";
import { useStore } from "./StoreContext";
import {
  FaArrowUpRightFromSquare,
  FaBoxOpen,
  FaGear,
  FaMobileScreenButton,
  FaShield,
} from "react-icons/fa6";

type WorkspaceView = "install" | "account" | "settings";

function App() {
  const { t } = useTranslation();

  const [operationState, setOperationState] = useState<OperationState | null>(
    null,
  );
  const [loggedInAs, setLoggedInAs] = useState<string | null>(null);
  const [selectedDevice, setSelectedDevice] = useState<DeviceInfo | null>(null);
  const [openModal, setOpenModal] = useState<
    null | "certificates" | "appids" | "pairing"
  >(null);
  const [version, setVersion] = useState<string>("");
  const [activeView, setActiveView] = useState<WorkspaceView>("install");

  const refreshDevicesRef = useRef<(() => void) | null>(null);
  const operationInFlightRef = useRef(false);
  const autoLoginAttemptedRef = useRef(false);
  const [refreshGuardEnabled] = useStore("refreshGuardEnabled", true);
  const [defaultAccount, setDefaultAccount] = useStore<string | null>(
    "defaultAccount",
    null,
  );
  const [anisetteServer] = useStore("anisetteServer", "ani.sidestore.io");

  const [noKeyringAvailable, setNoKeyringAvailable] = useState<boolean>(false);
  const { platform } = usePlatform();

  const checkKeyring = useCallback(async () => {
    try {
      let available = await invoke<boolean>("keyring_available");
      setNoKeyringAvailable(!available);
    } catch (e) {
      console.error("Unable to check keyring availability:", e);
      setNoKeyringAvailable(true);
    }
  }, []);

  useEffect(() => {
    checkKeyring();
  }, [checkKeyring]);

  useEffect(() => {
    const fetchVersion = async () => {
      const version = await getVersion();
      setVersion(version);
    };
    fetchVersion();
  }, []);

  useEffect(() => {
    if (loggedInAs) setDefaultAccount(loggedInAs);
  }, [loggedInAs, setDefaultAccount]);

  useEffect(() => {
    if (
      !refreshGuardEnabled ||
      loggedInAs ||
      !defaultAccount ||
      autoLoginAttemptedRef.current
    ) {
      return;
    }
    autoLoginAttemptedRef.current = true;
    invoke("login_stored", {
      email: defaultAccount,
      anisetteServer,
    })
      .then(() => setLoggedInAs(defaultAccount))
      .catch((error) => {
        console.error("Refresh Guard could not sign in automatically", error);
        setDefaultAccount(null);
      });
  }, [anisetteServer, defaultAccount, loggedInAs, refreshGuardEnabled]);

  useEffect(() => {
    if (!refreshGuardEnabled) return;
    const interval = window.setInterval(() => refreshDevicesRef.current?.(), 2 * 60 * 1000);
    return () => window.clearInterval(interval);
  }, [refreshGuardEnabled]);

  useEffect(() => {
    let dispose: (() => void)[] = [];
    Promise.all([
      listen("2fa-required", () => setActiveView("account")),
      listen("max-certs-reached", () => setActiveView("account")),
    ]).then((listeners) => { dispose = listeners; });
    return () => dispose.forEach((unlisten) => unlisten());
  }, []);

  const shortcutLabel = useCallback(
    (mac: string, windows: string, linux?: string) => {
      if (platform === "mac") return mac;
      if (platform === "linux") return linux ?? windows;
      return windows;
    },
    [platform],
  );

  const startOperation = useCallback(
    async (
      operation: Operation,
      params: { [key: string]: any },
    ): Promise<void> => {
      if (operationInFlightRef.current) {
        throw new Error("Another installation or refresh is already running");
      }
      operationInFlightRef.current = true;
      setOperationState({
        current: operation,
        started: [],
        failed: [],
        completed: [],
        progress: {},
      });
      return new Promise<void>(async (resolve, reject) => {
        const unlistenFn = await listen<OperationUpdate>(
          "operation_" + operation.id,
          (event) => {
            setOperationState((old) => {
              if (old == null) return null;
              if (event.payload.updateType === "started") {
                return {
                  ...old,
                  started: [...old.started, event.payload.stepId],
                };
              } else if (event.payload.updateType === "finished") {
                return {
                  ...old,
                  completed: [...old.completed, event.payload.stepId],
                };
              } else if (event.payload.updateType === "failed") {
                return {
                  ...old,
                  failed: [
                    ...old.failed,
                    {
                      stepId: event.payload.stepId,
                      extraDetails: event.payload.extraDetails,
                    },
                  ],
                };
              } else if (event.payload.updateType === "progress") {
                return {
                  ...old,
                  progress: {
                    ...old.progress,
                    [event.payload.stepId]: event.payload.progress,
                  },
                };
              }
              return old;
            });
          },
        );
        try {
          await invoke(operation.id + "_operation", params);
          unlistenFn();
          operationInFlightRef.current = false;
          resolve();
        } catch (e) {
          unlistenFn();
          operationInFlightRef.current = false;
          reject(e);
        }
      });
    },
    [setOperationState],
  );

  const ensuredLoggedIn = useCallback((): boolean => {
    if (loggedInAs) return true;
    toast.error(t("app.must_be_logged_in"));
    return false;
  }, [loggedInAs, t]);

  const ensureSelectedDevice = useCallback((): boolean => {
    if (selectedDevice) return true;
    toast.error(t("app.must_select_device"));
    return false;
  }, [selectedDevice, t]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === undefined) return;
      const key = event.key.toLowerCase();
      const primaryPressed = platform === "mac" ? event.metaKey : event.ctrlKey;
      if (!primaryPressed) return;

      if (!event.shiftKey && key === "p") {
        event.preventDefault();
        if (!ensureSelectedDevice()) return;
        setOpenModal("pairing");
      } else if (event.shiftKey && key === "c") {
        event.preventDefault();
        if (!ensuredLoggedIn()) return;
        setOpenModal("certificates");
      } else if (event.shiftKey && key === "a") {
        event.preventDefault();
        if (!ensuredLoggedIn()) return;
        setOpenModal("appids");
      } else if (!event.shiftKey && key === "r") {
        event.preventDefault();
        refreshDevicesRef.current?.();
      }
    };

    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [platform, ensureSelectedDevice, ensuredLoggedIn]);

  const pageCopy = {
    install: {
      eyebrow: "Workspace",
      title: "Install an app",
      subtitle: "Inspect the package, tailor its footprint, then deliver it to your iPhone.",
    },
    account: {
      eyebrow: "Signing",
      title: "Account & access",
      subtitle: "Keep Apple credentials, App IDs, certificates, and device trust in one place.",
    },
    settings: {
      eyebrow: "Preferences",
      title: "Sideloom settings",
      subtitle: "Tune signing services, storage, language, diagnostics, and pairing data.",
    },
  }[activeView];

  return (
    <main className="workspace">
      <aside className="workspace-sidebar">
        <div className="sidebar-drag-region" data-tauri-drag-region />
        <div className="brand-lockup">
          <img src={logo} alt="Sideloom icon" className="logo" />
          <div>
            <h1 className="title">Sideloom</h1>
            <span className="version-label">{t("version")} {version}</span>
          </div>
        </div>

        <nav className="sidebar-navigation" aria-label="Workspace">
          <button className={activeView === "install" ? "active" : ""} onClick={() => setActiveView("install")}>
            <FaBoxOpen aria-hidden="true" /><span>Install</span>
          </button>
          <button className={activeView === "account" ? "active" : ""} onClick={() => setActiveView("account")}>
            <FaShield aria-hidden="true" /><span>Account & access</span>
          </button>
          <button className={activeView === "settings" ? "active" : ""} onClick={() => setActiveView("settings")}>
            <FaGear aria-hidden="true" /><span>Settings</span>
          </button>
        </nav>

        <div className="sidebar-status">
          <div className="status-orb" data-connected={selectedDevice !== null}>
            <FaMobileScreenButton aria-hidden="true" />
          </div>
          <div>
            <strong>{selectedDevice?.name ?? "No iPhone selected"}</strong>
            <span>{selectedDevice ? `${selectedDevice.connectionType} · iOS ${selectedDevice.version}` : "Connect by USB or paired Wi-Fi"}</span>
          </div>
        </div>
        <div className="sidebar-account">
          <span className={loggedInAs ? "account-dot online" : "account-dot"} />
          <div><strong>{loggedInAs ?? "Apple Account required"}</strong><span>{loggedInAs ? "Ready to sign" : "Open Account & access"}</span></div>
        </div>
      </aside>

      <section className="workspace-stage">
        <header className="stage-toolbar" data-tauri-drag-region>
          <div className="stage-heading" data-tauri-drag-region>
            <span>{pageCopy.eyebrow}</span>
            <h2>{pageCopy.title}</h2>
            <p>{pageCopy.subtitle}</p>
          </div>
          <div className="toolbar-actions">
            {activeView === "install" && (
              <button className="toolbar-control" onClick={() => refreshDevicesRef.current?.()}>
                Refresh devices <kbd>{shortcutLabel("⌘R", "Ctrl+R")}</kbd>
              </button>
            )}
          </div>
        </header>

        <div className="stage-scroll">
          {activeView === "install" && (
            <div className="install-workspace">
              <section className="content-section device-section">
                <div className="content-section-title">
                  <div><span className="step-number">1</span><div><h3>Choose a destination</h3><p>Sideloom remembers trusted devices and can reconnect over your local network.</p></div></div>
                </div>
                <GlassCard className="content-card device-content-card">
                  <Device
                    selectedDevice={selectedDevice}
                    setSelectedDevice={setSelectedDevice}
                    registerRefresh={(fn) => { refreshDevicesRef.current = fn ?? null; }}
                  />
                </GlassCard>
              </section>
              <section className="content-section">
                <div className="content-section-title">
                  <div><span className="step-number">2</span><div><h3>Prepare your IPA</h3><p>Nothing is uploaded to a third-party service.</p></div></div>
                </div>
                <GlassCard className="content-card ipa-content-card">
                  <IpaWorkbench
                    selectedDevice={selectedDevice}
                    loggedInAs={loggedInAs}
                    canInstall={() => ensuredLoggedIn() && ensureSelectedDevice()}
                    startOperation={startOperation}
                  />
                </GlassCard>
              </section>
            </div>
          )}

          <div className={`account-workspace ${activeView === "account" ? "" : "workspace-hidden"}`}>
              <GlassCard className="content-card account-card">
                <AppleID loggedInAs={loggedInAs} setLoggedInAs={setLoggedInAs} noKeyringAvailable={noKeyringAvailable} />
              </GlassCard>
              <section className="management-section">
                <div className="content-section-title"><div><div><h3>Developer resources</h3><p>Inspect or repair the signing resources tied to your Personal Team.</p></div></div></div>
                <div className="management-grid">
                  <button onClick={() => { if (ensureSelectedDevice()) setOpenModal("pairing"); }}><strong>Pairing file</strong><span>Manage trust with the selected iPhone</span><kbd>{shortcutLabel("⌘P", "Ctrl+P")}</kbd></button>
                  <button onClick={() => { if (ensuredLoggedIn()) setOpenModal("certificates"); }}><strong>Certificates</strong><span>Review or revoke signing certificates</span><kbd>{shortcutLabel("⌘⇧C", "Ctrl+Shift+C")}</kbd></button>
                  <button onClick={() => { if (ensuredLoggedIn()) setOpenModal("appids"); }}><strong>App IDs</strong><span>See the identifiers consuming your free quota</span><kbd>{shortcutLabel("⌘⇧A", "Ctrl+Shift+A")}</kbd></button>
                </div>
              </section>
          </div>

          {activeView === "settings" && (
            <div className="settings-workspace">
              <GlassCard className="content-card settings-panel">
                <Settings
                  ensureSelectedDevice={ensureSelectedDevice}
                  setSelectedDevice={setSelectedDevice}
                  platform={platform}
                  shortcutLabel={shortcutLabel}
                  checkKeyring={checkKeyring}
                />
              </GlassCard>
              <button className="source-link" onClick={async () => {
                try { await openUrl("https://github.com/nab138/iloader"); }
                catch (error) { console.error("Failed to open GitHub link", error); toast.error(t("app.open_github_failed")); }
              }}>
                Open-source foundation and license <FaArrowUpRightFromSquare aria-hidden="true" />
              </button>
            </div>
          )}
        </div>
      </section>

      {operationState && (
        <OperationView operationState={operationState} closeMenu={() => setOperationState(null)} />
      )}
      <Modal
        isOpen={openModal === "certificates"}
        close={() => setOpenModal(null)}
      >
        <Certificates />
      </Modal>
      <Modal isOpen={openModal === "appids"} close={() => setOpenModal(null)}>
        <AppIds />
      </Modal>
      <Modal isOpen={openModal === "pairing"} close={() => setOpenModal(null)}>
        <Pairing />
      </Modal>
    </main>
  );
}

export default App;
