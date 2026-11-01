import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";
import { Modal } from "./components/Modal";
import "./ErrorContext.css";
import { toast } from "sonner";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Trans, useTranslation } from "react-i18next";
import { useStore } from "./StoreContext";
import {
  AppError,
  ErrorVariant,
  getErrorSuggestions,
  getHumanMessage,
  parseLinkToken,
} from "./errors";
import { usePlatform } from "./PlatformContext";

export const ErrorContext = createContext<{
  err: (msg: string, err: AppError) => string;
}>({ err: () => "" });

export const ErrorProvider: React.FC<{ children: React.ReactNode }> = ({
  children,
}) => {
  const { t } = useTranslation();
  const [msg, setMsg] = useState<string | null>(null);
  const [error, setError] = useState<AppError | null>(null);
  const [moreDetailsOpen, setMoreDetailsOpen] = useState<boolean>(false);
  const [suggestions, setSuggestions] = useState<string[]>([]);

  const [anisetteServer] = useStore<string>(
    "anisetteServer",
    "ani.sidestore.io",
  );
  const { platform } = usePlatform();

  const getSuggestions = useCallback(
    (type: ErrorVariant): string[] => {
      return getErrorSuggestions(t, type, platform, anisetteServer);
    },
    [anisetteServer, t, platform],
  );

  useEffect(() => {
    if (!error) {
      setSuggestions([]);
      return;
    }
    setSuggestions(getSuggestions(error.type));
  }, [error, getSuggestions]);

  return (
    <ErrorContext.Provider
      value={{
        err: (msg: string, err: AppError) => {
          console.log(err);
          setMsg(msg);
          setError(err);
          setMoreDetailsOpen(false);
          return msg;
        },
      }}
    >
      <Modal
        zIndex={999999999}
        isOpen={error !== null || msg !== null}
        close={() => {
          setError(null);
          setMsg(null);
          setMoreDetailsOpen(false);
        }}
      >
        <div className="error-outer">
          <div className="error-header">
            <h2>{t("error.title", { msg: msg ?? t("error.unknown") })}</h2>
            <button
              onClick={() => {
                navigator.clipboard.writeText(
                  "```\n" +
                    (error?.message.replace(/^\n+/, "") ??
                      t("common.no_error")) +
                    "\n```",
                );
                toast.success(t("common.copied_success"));
              }}
            >
              {t("common.copy_to_clipboard")}
            </button>
          </div>
          {/* Human-readable description — always shown prominently */}
          {error && (
            <div className="error-human-message">
              {getHumanMessage(error)}
            </div>
          )}
          {/* Technical chain — collapsed behind More Details */}
          <p
            className="error-more-details"
            role="button"
            tabIndex={0}
            onClick={() => setMoreDetailsOpen(!moreDetailsOpen)}
          >
            {t("common.more_details")} {moreDetailsOpen ? "▲" : "▼"}
          </p>
          {moreDetailsOpen && (
            <pre className="error-inner error-details">
              {error?.message.replace(/^\n+/, "")}
            </pre>
          )}

          <div className="suggestions">
            {suggestions.length > 0 && (
              <h3>{t("error.suggestions_heading")}</h3>
            )}
            {suggestions.length > 0 && (
              <ul>
                {suggestions.map((s) => (
                  <li key={s}>
                    {s
                      .split(/(\(\(link:[^)]+\)\)|\(\(link:[^)]+\)\))/g)
                      .map((part, index) => {
                        const parsed = parseLinkToken(part);
                        if (parsed) {
                          const { url, text } = parsed;
                          return (
                            <span
                              key={index}
                              onClick={() => openUrl(url)}
                              role="link"
                              className="error-link"
                            >
                              {text}
                            </span>
                          );
                        }
                        return <span key={index}>{part}</span>;
                      })}
                  </li>
                ))}
              </ul>
            )}
            {error?.type !== "underage" && (
              <p>
                <Trans
                  i18nKey="error.support_message"
                  components={{
                    discord: (
                      <span
                        onClick={() => openUrl("https://discord.gg/EA6yVgydBz")}
                        role="link"
                        className="error-link"
                      />
                    ),
                    github: (
                      <span
                        onClick={() =>
                          openUrl("https://github.com/nab138/iloader/issues")
                        }
                        role="link"
                        className="error-link"
                      />
                    ),
                  }}
                />
              </p>
            )}
          </div>

          <button
            onClick={() => {
              setError(null);
              setMsg(null);
            }}
          >
            {t("common.dismiss")}
          </button>
        </div>
      </Modal>
      {children}
    </ErrorContext.Provider>
  );
};

export const useError = () => {
  return useContext(ErrorContext);
};
