import { preferenceStorage, draftStorage } from "../browser-storage";
import { useCallback, useMemo, useState } from "react";
import { appPath, composerDraftKey, type OptionValue } from "../session";
import { useCtx } from "../context";
import { readStoredProviderOptions, updateStoredProviderOption } from "../options-store";
import { agentChatText } from "../i18n";
import { ArrowUp } from "./icons";
import { StatusRow } from "./StatusRow";
import { isCtrlJ, insertNewlineAtCaret, useCommandMenu } from "./CommandMenu";
import { sanitizeStartOptions, withLocalValues } from "./options";
import { ShortcutOverlay, useKeymap } from "../hooks/useKeymap";
import { useAutoGrow } from "../hooks/useAutoGrow";
import {
  loadingProviderOptionIds,
  providerOptionMap,
  useCwdErrorFallback,
  useCwdValidation,
  useDefaultCwd,
  useFileCatalog,
  useProviderCatalogs,
  useProviderFallback,
  withFileTrigger,
} from "../hooks/useCatalogs";


const readProviderOptions = readStoredProviderOptions;
function initialCwd() {
  const requested = new URLSearchParams(globalThis.location?.search ?? "").get("cwd");
  return requested?.startsWith("/") ? requested : preferenceStorage.getItem("agentui.cwd") || "";
}

export function Composer() {
  const {
    ready,
    recentSessions,
    connectionEpoch,
    providers,
    capabilities,
    defaultCwd,
    providerOptions,
    providerCommands,
    filesByCwd,
    cwdChecks,
    lastError,
    ctrlJ,
    requestProviderOptions,
    requestProviderCommands,
    requestFiles,
    checkCwd,
    clearError,
    start,
  } = useCtx();
  const [provider, setProvider] = useState(() => preferenceStorage.getItem("agentui.provider") || "claude");
  const [cwd, setCwd] = useState(initialCwd);
  const [committedCwd, setCommittedCwd] = useState(initialCwd);
  const [prompt, setPrompt] = useState(() => {
    const draft = draftStorage.getItem(composerDraftKey) || "";
    draftStorage.removeItem(composerDraftKey);
    return draft;
  });
  const [startOptionsByProvider, setStartOptionsByProvider] = useState<Record<string, Record<string, OptionValue>>>(() => ({
    [provider]: readProviderOptions(provider),
  }));
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const taRef = useAutoGrow(prompt, 300);
  const baseOptions = providerOptions[provider]?.length ? providerOptions[provider] : capabilities[provider]?.options ?? [];
  const allProviderOptions = providerOptionMap(providers, providerOptions, capabilities);
  const loadingProviderIds = useMemo(
    () => loadingProviderOptionIds(providers, providerOptions),
    [providerOptions, providers],
  );
  const startOptions = startOptionsByProvider[provider] ?? {};
  const options = withLocalValues(baseOptions, startOptions);
  const commandGroups = useMemo(() => withFileTrigger(providerCommands[provider] ?? [], filesByCwd[committedCwd] ?? []), [committedCwd, filesByCwd, provider, providerCommands]);
  const commandMenu = useCommandMenu(prompt, setPrompt, commandGroups, taRef, ctrlJ);

  useDefaultCwd(defaultCwd, cwd, setCwd, committedCwd, setCommittedCwd);
  useProviderFallback(providers, provider, setProvider);
  useProviderCatalogs(ready, connectionEpoch, providers, provider, committedCwd, requestProviderOptions, requestProviderCommands);
  useFileCatalog(ready, connectionEpoch, committedCwd, requestFiles);
  useCwdValidation(ready, connectionEpoch, committedCwd, defaultCwd, cwdChecks, checkCwd, setCwd, setCommittedCwd);
  useCwdErrorFallback(lastError, defaultCwd, setCwd, setCommittedCwd);

  const setLocalOption = useCallback((id: string, value: OptionValue) => {
    setStartOptionsByProvider((all) => {
      const nextForProvider = updateStoredProviderOption(provider, id, value, options);
      return { ...all, [provider]: nextForProvider };
    });
  }, [options, provider]);
  useKeymap({
    options: options.filter(option => option.id !== "mode"),
    setOption: setLocalOption,
    running: false,
    stop: () => {},
    helpOpen,
    setHelpOpen,
    popupOpen: commandMenu.open || Boolean(openOptionId),
    closePopup: () => {
      commandMenu.close();
      setOpenOptionId(null);
    },
    ctrlJ,
    inputRef: taRef,
    openModel: () => setOpenOptionId("modelPicker"),
  });

  const submit = () => {
    const text = prompt.trim();
    if (!text || !ready) return;
    const runCwd = cwd.trim();
    const sent = start({ provider, cwd: runCwd, prompt: text, options: sanitizeStartOptions(startOptions, options) });
    if (!sent) return;
    preferenceStorage.setItem("agentui.provider", provider);
    preferenceStorage.setItem("agentui.cwd", runCwd);
  };
  const changeCwd = (v: string) => { setCwd(v); };
  const commitCwd = (v: string) => {
    const next = v.trim();
    if (!next) return;
    setCommittedCwd(next);
    preferenceStorage.setItem("agentui.cwd", next);
  };
  const changeProvider = (v: string) => {
    setProvider(v);
    setStartOptionsByProvider((all) => all[v] ? all : { ...all, [v]: readProviderOptions(v) });
    preferenceStorage.setItem("agentui.provider", v);
  };
  const changeProviderModel = (nextProvider: string, model: string) => {
    changeProvider(nextProvider);
    setStartOptionsByProvider((all) => {
      const nextForProvider = updateStoredProviderOption(nextProvider, "model", model, allProviderOptions[nextProvider] ?? []);
      return { ...all, [nextProvider]: nextForProvider };
    });
    setOpenOptionId(null);
  };

  return (
    <section id="composer-view">
      <div id="composer-card">
        <div className="input-wrap">
          <textarea
            ref={taRef}
            id="prompt-input"
            data-primary-textarea="true"
            placeholder="Describe a task or ask a question…"
            value={prompt}
            autoFocus
            onChange={(e) => {
              setPrompt(e.target.value);
              if (lastError) clearError();
            }}
            onSelect={commandMenu.onSelect}
            onKeyUp={commandMenu.onSelect}
            onClick={commandMenu.onSelect}
            onKeyDown={(e) => {
              if (commandMenu.onKeyDown(e)) return;
              if (isCtrlJ(e)) { e.preventDefault(); insertNewlineAtCaret(prompt, setPrompt, taRef); return; }
              if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
            }}
          />
          {commandMenu.menu}
        </div>
        <StatusRow
          provider={provider}
          providers={providers}
          allProviderOptions={allProviderOptions}
          loadingProviderIds={loadingProviderIds}
          onProviderModelChange={changeProviderModel}
          cwd={cwd}
          onCwdChange={changeCwd}
          onCwdCommit={commitCwd}
          options={options}
          onChange={setLocalOption}
          openOptionId={openOptionId}
          setOpenOptionId={setOpenOptionId}
          trailing={(
            <button className="send" type="button" aria-label="Start" disabled={!prompt.trim() || !ready} onClick={submit}>
              <ArrowUp />
            </button>
          )}
        />
      </div>
      {recentSessions?.some(chat => chat.mode !== "transcript" && chat.cwd === cwd) ? (
        <section className="recent-chats" aria-label={agentChatText("recentConversations")}>
          <h2>{agentChatText("recentConversations")}</h2>
          {recentSessions.filter(chat => chat.mode !== "transcript" && chat.cwd === cwd).slice(0, 12).map(chat => (
            <a key={chat.id} href={appPath(`/s/${chat.id}`)}>
              <span>{chat.title}</span><small>{chat.provider}</small>
            </a>
          ))}
        </section>
      ) : null}
      {lastError ? <div className="composer-error">{lastError}</div> : null}
      <div id="composer-hint">Enter to start · Shift+Enter for newline · Ctrl+/ for shortcuts</div>
      {helpOpen ? <ShortcutOverlay provider={provider} options={options.filter(option => option.id !== "mode")} running={false} ctrlJ={ctrlJ} onClose={() => setHelpOpen(false)} /> : null}
    </section>
  );
}
