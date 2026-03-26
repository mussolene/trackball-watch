<script lang="ts">
  export let status: string;
  export let peer: { addr: string } | null = null;

  $: color = status === 'connected' ? '#34c759'
    : status === 'connecting' ? '#ff9500'
    : '#ff3b30';

  $: label = status === 'connected' ? 'Connected'
    : status === 'connecting' ? 'Connecting…'
    : 'Disconnected';
</script>

<div class="status-bar">
  <div class="dot" style="background: {color}"></div>
  <span class="label">{label}</span>
  {#if peer}
    <span class="peer">{peer.addr}</span>
  {/if}
</div>

<style>
  .status-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 0;
    margin-bottom: 8px;
    border-bottom: 1px solid #f0f0f0;
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
</style>
