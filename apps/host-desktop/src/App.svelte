<script lang="ts">
  import { onMount } from 'svelte';
  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import QRCode from 'qrcode';
  import Settings from './components/Settings.svelte';
  import StatusBar from './components/StatusBar.svelte';

  interface ConnectedPeer { addr: string }
  interface ConnectionStatus { state: string; peer: ConnectedPeer | null }
  interface PairingHost {
    host: string;
    interface: string;
  }
  interface PairingInfo {
    pairing_url: string;
    host: string;
    port: number;
    device_id: string;
    pin: string;
    interface: string;
    hosts: PairingHost[];
  }

  let config: any = defaultConfig();
  let connectionStatus: ConnectionStatus = { state: 'disconnected', peer: null };
  let activeTab = 'settings';
  let qrDataUrl = '';
  let pairingInfo: PairingInfo | null = null;
  let loadError: string | null = null;
  let toast: string | null = null;
  let toastTimer: ReturnType<typeof setTimeout> | undefined;
  /** macOS Accessibility permission state. Optimistic default; checked on mount. */
  let hasAccessibility = true;
  let accessibilityCheckInterval: ReturnType<typeof setInterval> | undefined;

  async function checkAccessibility() {
    try {
      hasAccessibility = await invoke<boolean>('check_accessibility');
    } catch { /* ignore on non-macOS */ }
  }

  async function grantAccessibility() {
    try { await invoke('open_accessibility_settings'); } catch {}
  }

  function showToast(msg: string) {
    clearTimeout(toastTimer);
    toast = msg;
    toastTimer = setTimeout(() => { toast = null; }, 4000);
  }

  /** Sync WebView `data-theme` with Tauri window theme (WKWebView often ignores CSS `prefers-color-scheme`). */
  async function applyWindowTheme() {
    const win = getCurrentWindow();
    const t = await win.theme();
    const resolved =
      t ?? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    document.documentElement.setAttribute('data-theme', resolved);
  }

  function defaultConfig() {
    return {
      sensitivity: 1.0,
      mode: 'trackpad',
      hand: 'right',
      accel: {
        curve: 's_curve',
        sensitivity: 1.0,
        knee_point: 5.0,
        max_delta: 40.0
      },
      kalman_q_pos: 0.1,
      kalman_q_vel: 1.0,
      kalman_r_noise: 0.5,
      trackball_friction: 0.92,
      udp_port: 47474,
      start_minimized: true,
      start_on_login: false
    };
  }

  async function loadInitialData() {
    loadError = null;
    try {
      config = await invoke('get_config');
    } catch (e) {
      // Keep UI usable even if backend config command fails.
      config = defaultConfig();
      loadError = 'Failed to load desktop settings. Showing defaults.';
    }

    try {
      connectionStatus = await invoke('get_connection_status');
    } catch (e) {
      connectionStatus = { state: 'disconnected', peer: null };
      loadError ??= 'Failed to read connection status.';
    }

    try {
      await loadPairingInfo();
    } catch (e) {
      loadError ??= 'Failed to load pairing info (QR/PIN).';
      pairingInfo = null;
      qrDataUrl = '';
    }
  }

  onMount(() => {
    let unlistenStatus: (() => void) | undefined;
    let unlistenPairing: (() => void) | undefined;
    let unlistenTheme: (() => void) | undefined;
    let unlistenFocus: (() => void) | undefined;
    let mqListener: ((this: MediaQueryList, ev: MediaQueryListEvent) => void) | undefined;

    (async () => {
      await applyWindowTheme();
      const win = getCurrentWindow();
      unlistenTheme = await win.onThemeChanged(() => {
        void applyWindowTheme();
      });
      const mq = window.matchMedia('(prefers-color-scheme: dark)');
      mqListener = () => {
        void applyWindowTheme();
      };
      mq.addEventListener('change', mqListener);

      unlistenFocus = await win.onFocusChanged(async ({ payload: focused }) => {
        if (focused) {
          connectionStatus = await invoke('get_connection_status');
        }
      });

      await loadInitialData();
      await checkAccessibility();
      if (!hasAccessibility) {
        accessibilityCheckInterval = setInterval(async () => {
          await checkAccessibility();
          if (hasAccessibility && accessibilityCheckInterval) {
            clearInterval(accessibilityCheckInterval);
            accessibilityCheckInterval = undefined;
          }
        }, 3000);
      }

      // Event-driven status — no polling needed
      unlistenStatus = await listen<ConnectionStatus>('connection_status_changed', (event) => {
        const prev = connectionStatus.state;
        connectionStatus = event.payload;
        if (event.payload.state === 'connected') {
          showToast(`Device connected: ${event.payload.peer?.addr ?? ''}`);
        } else if (prev === 'connected') {
          showToast('Device disconnected');
        }
      });

      unlistenPairing = await listen('open_pairing_tab', async () => {
        activeTab = 'pairing';
        if (!pairingInfo) await loadPairingInfo();
      });
    })();

    return () => {
      unlistenStatus?.();
      unlistenPairing?.();
      unlistenTheme?.();
      unlistenFocus?.();
      if (mqListener) {
        window.matchMedia('(prefers-color-scheme: dark)').removeEventListener('change', mqListener);
      }
      if (accessibilityCheckInterval) clearInterval(accessibilityCheckInterval);
    };
  });

  async function saveConfig() {
    try {
      await invoke('save_config', { config });
    } catch (e: any) {
      const msg = typeof e === 'string' ? e : (e?.message ?? 'unknown error');
      showToast(`Failed to save setting: ${msg}`);
    }
  }

  async function loadPairingInfo() {
    pairingInfo = await invoke<PairingInfo>('get_pairing_info');
    qrDataUrl = await QRCode.toDataURL(pairingInfo.pairing_url, { width: 200, margin: 1 });
  }

  async function refreshPairingInfo() {
    try {
      await loadPairingInfo();
      showToast('Pairing info refreshed');
    } catch {
      loadError = 'Failed to refresh pairing info.';
    }
  }

  async function disconnectDevice() {
    await invoke('disconnect_device');
  }
</script>

<main>
  {#if !hasAccessibility}
    <div class="accessibility-banner">
      <span>⚠ Accessibility permission required for cursor control.</span>
      <button class="grant-btn" on:click={grantAccessibility}>Open Settings</button>
    </div>
  {/if}

  {#if toast}
    <div class="toast" class:toast-connected={connectionStatus.state === 'connected'}>
      {toast}
      <button class="toast-close" on:click={() => (toast = null)}>✕</button>
    </div>
  {/if}

  <StatusBar status={connectionStatus.state} peer={connectionStatus.peer} />

  <nav>
    <button class:active={activeTab === 'settings'} on:click={() => (activeTab = 'settings')}>
      Settings
    </button>
    <button class:active={activeTab === 'pairing'} on:click={() => (activeTab = 'pairing')}>
      Pairing
    </button>
    {#if connectionStatus.state === 'connected'}
      <button class="disconnect-btn" on:click={disconnectDevice}>Disconnect</button>
    {/if}
  </nav>

  <section class="content-panel">
    {#if loadError}
      <div class="error-banner">{loadError}</div>
    {/if}
    {#if activeTab === 'settings'}
      <Settings bind:config on:save={saveConfig} />
    {:else if activeTab === 'pairing'}
      <div class="pairing-tab">
        <p>In iPhone app: connect this desktop, keep relay active, then move finger on watch trackpad.</p>
        {#if qrDataUrl && pairingInfo}
          <img src={qrDataUrl} alt="Pairing QR" class="qr-image" />
          <small class="pairing-line">PIN: <b>{pairingInfo.pin}</b></small>
          <small class="pairing-line">{pairingInfo.host}:{pairingInfo.port}</small>
          <small class="pairing-line">Interface: {pairingInfo.interface}</small>
          {#if pairingInfo.hosts?.length}
            <div class="host-list">
              {#each pairingInfo.hosts as h}
                <small class="pairing-line mono">{h.interface}: {h.host}:{pairingInfo.port}</small>
              {/each}
            </div>
          {/if}
          <small class="pairing-line mono">{pairingInfo.pairing_url}</small>
        {:else}
          <div class="qr-placeholder"><span>QR unavailable</span></div>
          <small class="pairing-line">Open iPhone app and use manual IP entry: port 47474.</small>
        {/if}
        <button class="refresh-btn" on:click={refreshPairingInfo}>Refresh QR/PIN</button>
      </div>
    {/if}
  </section>

</main>

<style>
  :global(html),
  :global(body),
  :global(#app) {
    height: 100%;
    background: #fff;
  }

  :global(html[data-theme="dark"]),
  :global(html[data-theme="dark"] body),
  :global(html[data-theme="dark"] #app) {
    background: #1c1c1e;
    color: #f2f2f7;
  }

  :global(body) {
    margin: 0;
    background: inherit;
    color: #1a1a1a;
  }

  :global(html[data-theme="dark"] body) {
    color: #f2f2f7;
  }

  main {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    width: 100%;
    max-width: 460px;
    min-height: 100%;
    margin: 0 auto;
    padding: 14px 16px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    background: inherit;
  }

  nav {
    display: flex;
    gap: 8px;
    margin-bottom: 0;
    border-bottom: 1px solid #e0e0e0;
    padding-bottom: 8px;
    align-items: center;
  }
  :global(html[data-theme="dark"]) nav {
    border-bottom-color: #3a3a3c;
  }

  nav button {
    background: none;
    border: none;
    padding: 6px 12px;
    cursor: pointer;
    border-radius: 6px;
    font-size: 14px;
    color: #666;
  }
  :global(html[data-theme="dark"]) nav button {
    color: #aeaeb2;
  }

  nav button.active {
    background: #007aff;
    color: white;
  }

  .disconnect-btn {
    margin-left: auto;
    color: #ff3b30 !important;
    font-size: 13px !important;
  }

  .disconnect-btn:hover { background: #fff0f0 !important; }
  :global(html[data-theme="dark"]) .disconnect-btn:hover {
    background: #2c1a1a !important;
  }

  .toast {
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: #1c1c1e;
    color: white;
    padding: 10px 14px;
    border-radius: 10px;
    font-size: 13px;
    margin-bottom: 12px;
    animation: slide-in 0.2s ease;
  }

  .toast-connected {
    background: #1a3a1a;
    border-left: 3px solid #34c759;
  }

  .toast-close {
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.6);
    cursor: pointer;
    font-size: 12px;
    padding: 0 0 0 8px;
  }

  @keyframes slide-in {
    from { opacity: 0; transform: translateY(-8px); }
    to   { opacity: 1; transform: translateY(0); }
  }

  .refresh-btn {
    margin-top: 8px;
    border: 1px solid #0a84ff;
    background: #0a84ff;
    color: white;
    border-radius: 8px;
    padding: 6px 10px;
    font-size: 12px;
    cursor: pointer;
  }

  .error-banner {
    background: rgba(255, 59, 48, 0.12);
    color: #ff3b30;
    border: 1px solid rgba(255, 59, 48, 0.35);
    border-radius: 8px;
    font-size: 12px;
    padding: 8px 10px;
    margin-bottom: 10px;
  }

  .content-panel {
    border: 1px solid #e5e5ea;
    border-radius: 12px;
    padding: 14px;
    background: rgba(0, 0, 0, 0.02);
    min-height: 280px;
  }

  :global(html[data-theme="dark"]) .content-panel {
    border-color: #3a3a3c;
    background: rgba(255, 255, 255, 0.02);
  }

  .pairing-tab {
    padding: 8px 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
  }

  .qr-placeholder,
  .qr-image {
    width: 200px;
    height: 200px;
    border-radius: 12px;
  }

  .qr-placeholder {
    border: 2px dashed #ccc;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    margin: 16px 0;
    gap: 8px;
  }
  :global(html[data-theme="dark"]) .qr-placeholder {
    border-color: #48484a;
  }

  .qr-placeholder span {
    font-size: 18px;
    color: #999;
  }

  .pairing-line { color: #666; }
  :global(html[data-theme="dark"]) .pairing-line {
    color: #aeaeb2;
  }

  .mono {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 11px;
    text-align: center;
    word-break: break-all;
  }

  .accessibility-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: rgba(255, 159, 10, 0.15);
    border: 1px solid rgba(255, 159, 10, 0.5);
    border-radius: 10px;
    padding: 10px 14px;
    font-size: 13px;
    color: #c67b00;
    gap: 12px;
  }
  :global(html[data-theme="dark"]) .accessibility-banner {
    color: #ff9f0a;
    background: rgba(255, 159, 10, 0.1);
    border-color: rgba(255, 159, 10, 0.35);
  }

  .grant-btn {
    flex-shrink: 0;
    border: 1px solid currentColor;
    background: none;
    color: inherit;
    border-radius: 6px;
    padding: 4px 10px;
    font-size: 12px;
    cursor: pointer;
  }
  .grant-btn:hover { opacity: 0.75; }

  .host-list {
    display: flex;
    flex-direction: column;
    gap: 2px;
    margin-top: 4px;
    margin-bottom: 4px;
    align-items: center;
  }
</style>
