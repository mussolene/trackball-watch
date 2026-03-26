<script lang="ts">
  import { onMount } from 'svelte';
  import { invoke } from '@tauri-apps/api/core';
  import Settings from './components/Settings.svelte';
  import StatusBar from './components/StatusBar.svelte';

  let config: any = null;
  let status = 'disconnected';
  let activeTab = 'settings';

  onMount(async () => {
    config = await invoke('get_config');
    status = await invoke('get_connection_status');
    // Poll status every 2s
    setInterval(async () => {
      status = await invoke('get_connection_status');
    }, 2000);
  });

  async function saveConfig() {
    await invoke('save_config', { config });
  }
</script>

<main>
  <StatusBar {status} />

  <nav>
    <button class:active={activeTab === 'settings'} on:click={() => activeTab = 'settings'}>
      Settings
    </button>
    <button class:active={activeTab === 'pairing'} on:click={() => activeTab = 'pairing'}>
      Pairing
    </button>
  </nav>

  {#if config}
    {#if activeTab === 'settings'}
      <Settings bind:config on:save={saveConfig} />
    {:else if activeTab === 'pairing'}
      <div class="pairing-tab">
        <p>Launch the iPhone app and tap "Pair New Desktop" to connect.</p>
        <div class="qr-placeholder">
          <span>QR Code</span>
          <small>Start the app to generate pairing code</small>
        </div>
      </div>
    {/if}
  {:else}
    <div class="loading">Loading…</div>
  {/if}
</main>

<style>
  main {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    max-width: 400px;
    margin: 0 auto;
    padding: 16px;
    color: #1a1a1a;
  }

  nav {
    display: flex;
    gap: 8px;
    margin-bottom: 16px;
    border-bottom: 1px solid #e0e0e0;
    padding-bottom: 8px;
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

  nav button.active {
    background: #007aff;
    color: white;
  }

  .loading {
    text-align: center;
    color: #999;
    padding: 32px;
  }

  .pairing-tab {
    padding: 16px 0;
  }

  .qr-placeholder {
    width: 200px;
    height: 200px;
    border: 2px dashed #ccc;
    border-radius: 12px;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    margin: 16px auto;
    gap: 8px;
  }

  .qr-placeholder span {
    font-size: 18px;
    color: #999;
  }

  .qr-placeholder small {
    font-size: 12px;
    color: #bbb;
    text-align: center;
    padding: 0 16px;
  }
</style>
