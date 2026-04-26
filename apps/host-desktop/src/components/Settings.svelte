<script lang="ts">
  import { createEventDispatcher } from 'svelte';

  export let config: any;
  const dispatch = createEventDispatcher();

  function save() {
    dispatch('save');
  }

  function clampUdpPort() {
    let p = Math.round(Number(config.udp_port));
    if (!Number.isFinite(p)) p = 47474;
    config.udp_port = Math.min(65535, Math.max(1024, p));
  }

  function savePort() {
    clampUdpPort();
    save();
  }

  $: sensitivityPct = Math.round(config?.sensitivity * 100) ?? 100;
</script>

<div class="settings">
  <section>
    <h3>Sensitivity <span class="value">{sensitivityPct}%</span></h3>
    <input
      type="range"
      min="0.1"
      max="3.0"
      step="0.05"
      bind:value={config.sensitivity}
      on:change={save}
    />
  </section>

  <section>
    <h3>Acceleration Curve</h3>
    <select bind:value={config.accel.curve} on:change={save}>
      <option value="s_curve">S-Curve (recommended)</option>
      <option value="linear">Linear</option>
      <option value="quadratic">Quadratic</option>
    </select>
  </section>

  <section class="friction-slot">
    <h3>Trackball friction <span class="value">{Math.round(config.trackball_friction * 100)}%</span></h3>
    <input
      type="range"
      min="0.55"
      max="0.99"
      step="0.01"
      bind:value={config.trackball_friction}
      on:change={save}
    />
    <small>Higher = longer coasting</small>
  </section>

  <section>
    <h3>Network</h3>
    <label class="row-label">
      UDP port (TBP)
      <input
        type="number"
        min="1024"
        max="65535"
        step="1"
        class="port-input"
        bind:value={config.udp_port}
        on:change={savePort}
      />
    </label>
    <small>Default 47474. After changing the port, restart the app so the listener and mDNS use the new value.</small>
  </section>

  <section>
    <h3>Smoothing</h3>
    <select bind:value={config.smoothing_profile} on:change={save}>
      <option value="precise">Precise — documents &amp; code (less lag at rest)</option>
      <option value="balanced">Balanced — general use</option>
      <option value="responsive">Responsive — fast scrolling</option>
      <option value="custom">Custom</option>
    </select>
    {#if config.smoothing_profile === 'custom'}
      <label class="row-label">
        Min cutoff <span class="value">{config.one_euro_min_cutoff?.toFixed(2) ?? '1.00'} Hz</span>
        <input type="range" min="0.1" max="10" step="0.1"
          bind:value={config.one_euro_min_cutoff} on:change={save} />
      </label>
      <label class="row-label">
        Beta <span class="value">{config.one_euro_beta?.toFixed(4) ?? '0.0070'}</span>
        <input type="range" min="0.001" max="0.1" step="0.001"
          bind:value={config.one_euro_beta} on:change={save} />
      </label>
    {/if}
  </section>

  <section>
    <label class="checkbox-label">
      <input
        type="checkbox"
        bind:checked={config.start_on_login}
        on:change={save}
      />
      Start on login
    </label>
    <label class="checkbox-label">
      <input
        type="checkbox"
        bind:checked={config.start_minimized}
        on:change={save}
      />
      Start minimized to tray
    </label>
  </section>
</div>

<style>
  .settings {
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  h3 {
    font-size: 13px;
    font-weight: 600;
    color: #666;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin: 0;
  }
  :global(html[data-theme="dark"]) h3 {
    color: #aeaeb2;
  }

  .value {
    font-weight: 400;
    color: #007aff;
    text-transform: none;
  }

  .row-label {
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: 12px;
    color: #555;
  }
  :global(html[data-theme="dark"]) .row-label {
    color: #aeaeb2;
  }

  input[type="range"] {
    width: 100%;
    accent-color: #007aff;
  }

  select {
    padding: 8px;
    border: 1px solid #ddd;
    border-radius: 8px;
    font-size: 14px;
    background: white;
    width: 100%;
    color: #1a1a1a;
  }
  :global(html[data-theme="dark"]) select {
    background: #2c2c2e;
    border-color: #48484a;
    color: #f2f2f7;
  }

  small {
    font-size: 11px;
    color: #999;
  }

  .checkbox-label {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 14px;
    cursor: pointer;
  }

  .friction-slot {
    min-height: 88px;
  }

  .port-input {
    padding: 8px 10px;
    border: 1px solid #ddd;
    border-radius: 8px;
    font-size: 14px;
    width: 100%;
    max-width: 140px;
    box-sizing: border-box;
    background: white;
    color: #1a1a1a;
  }
  :global(html[data-theme='dark']) .port-input {
    background: #2c2c2e;
    border-color: #48484a;
    color: #f2f2f7;
  }
</style>
