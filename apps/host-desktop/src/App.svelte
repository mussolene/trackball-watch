<script lang="ts">
  import { onMount } from 'svelte';
  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import QRCode from 'qrcode';
  import Settings from './components/Settings.svelte';
  import StatusBar from './components/StatusBar.svelte';

  interface ConnectedPeer { addr: string }
  interface ConnectionStatus { state: string; peer: ConnectedPeer | null }

  let config: any = null;
  let connectionStatus: ConnectionStatus = { state: 'disconnected', peer: null };
  let activeTab = 'settings';
  let qrDataUrl = '';
  let pairingInfo: any = null;
  let toast: string | null = null;
  let toastTimer: ReturnType<typeof setTimeout> | undefined;

  function showToast(msg: string) {
    clearTimeout(toastTimer);
    toast = msg;
    toastTimer = setTimeout(() => { toast = null; }, 4000);
  }

  onMount(() => {
    let unlistenStatus: (() => void) | undefined;
    let unlistenPairing: (() => void) | undefined;

    (async () => {
      config = await invoke('get_config');
      connectionStatus = await invoke('get_connection_status');
      await loadPairingInfo();

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
    };
  });

  async function saveConfig() {
    await invoke('save_config', { config });
  }

  async function loadPairingInfo() {
    pairingInfo = await invoke('get_pairing_info');
    qrDataUrl = await QRCode.toDataURL(pairingInfo.pairing_url, { width: 200, margin: 1 });
  }

  async function disconnectDevice() {
    await invoke('disconnect_device');
  }
</script>

<main>
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

  {#if config}
    {#if activeTab === 'settings'}
      <Settings bind:config on:save={saveConfig} />
    {:else if activeTab === 'pairing'}
      <div class="pairing-tab">
        <p>Launch the iPhone app and tap "Pair New Desktop" to connect.</p>
        {#if qrDataUrl && pairingInfo}
          <img src={qrDataUrl} alt="Pairing QR" class="qr-image" />
          <small class="pairing-line">PIN: <b>{pairingInfo.pin}</b></small>
          <small class="pairing-line">{pairingInfo.host}:{pairingInfo.port}</small>
          <small class="pairing-line mono">{pairingInfo.pairing_url}</small>
        {:else}
          <div class="qr-placeholder"><span>Generating QR…</span></div>
        {/if}
      </div>
    {/if}
  {:else}
    <div class="loading">Loading…</div>
  {/if}
</main>

<style>
  :global(body) { background: #fff; color: #1a1a1a; }
  @media (prefers-color-scheme: dark) {
    :global(body) { background: #1c1c1e; color: #f2f2f7; }
  }

  main {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    max-width: 400px;
    margin: 0 auto;
    padding: 16px;
  }

  nav {
    display: flex;
    gap: 8px;
    margin-bottom: 16px;
    border-bottom: 1px solid #e0e0e0;
    padding-bottom: 8px;
    align-items: center;
  }
  @media (prefers-color-scheme: dark) {
    nav { border-bottom-color: #3a3a3c; }
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
  @media (prefers-color-scheme: dark) {
    nav button { color: #aeaeb2; }
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
  @media (prefers-color-scheme: dark) {
    .disconnect-btn:hover { background: #2c1a1a !important; }
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

  .loading {
    text-align: center;
    color: #999;
    padding: 32px;
  }

  .pairing-tab {
    padding: 16px 0;
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
  @media (prefers-color-scheme: dark) {
    .qr-placeholder { border-color: #48484a; }
  }

  .qr-placeholder span {
    font-size: 18px;
    color: #999;
  }

  .pairing-line { color: #666; }
  @media (prefers-color-scheme: dark) {
    .pairing-line { color: #aeaeb2; }
  }

  .mono {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 11px;
    text-align: center;
    word-break: break-all;
  }
</style>
