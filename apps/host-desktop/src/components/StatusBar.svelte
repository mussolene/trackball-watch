<script lang="ts">
  export let status: string;
  export let peer: { addr: string } | null = null;

  $: color = status === 'connected' ? '#34c759'
    : status === 'connecting' ? '#ff9500'
    : '#ff3b30';

  $: label = status === 'connected' ? 'iPhone relay: connected'
    : status === 'connecting' ? 'iPhone relay: connecting…'
    : 'iPhone relay: waiting for packets';
</script>

<div class="status-bar">
  <div class="dot" style="background: {color}"></div>
  <span class="label">{label}</span>
  {#if status === 'connected'}
    <span class="peer" title="Current relay endpoint">{peer?.addr ?? 'relay active'}</span>
  {:else}
    <span class="hint">Open iPhone app, then touch watch trackpad.</span>
  {/if}
</div>

{#if status === 'connected'}
  <div class="clients">
    <div class="clients-title">Connected Clients</div>
    <div class="client-row">
      <span class="client-pill">iPhone relay</span>
      <span class="client-addr">{peer?.addr ?? 'unknown'}</span>
    </div>
  </div>
{/if}

<style>
  .status-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 0;
    margin-bottom: 8px;
    border-bottom: 1px solid #f0f0f0;
    flex-wrap: wrap;
  }
  :global(html[data-theme="dark"]) .status-bar {
    border-bottom-color: #3a3a3c;
  }

  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
    transition: background 0.3s;
  }

  .label {
    font-size: 13px;
    font-weight: 500;
  }

  .peer {
    font-size: 11px;
    color: #888;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    margin-left: 4px;
  }

  .hint {
    font-size: 11px;
    color: #888;
    margin-left: 4px;
  }

  .clients {
    margin-top: -4px;
    margin-bottom: 8px;
    border: 1px solid #e5e5ea;
    border-radius: 10px;
    padding: 8px 10px;
    background: rgba(0, 0, 0, 0.02);
  }
  :global(html[data-theme="dark"]) .clients {
    border-color: #3a3a3c;
    background: rgba(255, 255, 255, 0.02);
  }

  .clients-title {
    font-size: 11px;
    color: #8e8e93;
    margin-bottom: 6px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .client-row {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    align-items: center;
  }

  .client-pill {
    font-size: 11px;
    color: #34c759;
    background: rgba(52, 199, 89, 0.14);
    border: 1px solid rgba(52, 199, 89, 0.32);
    border-radius: 999px;
    padding: 2px 8px;
  }

  .client-addr {
    font-size: 11px;
    color: #888;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
</style>
