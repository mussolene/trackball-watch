<script lang="ts">
  import { createEventDispatcher } from 'svelte';
  import { invoke } from '@tauri-apps/api/core';

  export let config: any;
  const dispatch = createEventDispatcher();

  function save() {
    dispatch('save');
  }

  function setMode(mode: string) {
    config.mode = mode;
    save();
    invoke('push_mode').catch(() => {});
  }

  $: sensitivityPct = Math.round(config?.sensitivity * 100) ?? 100;
</script>

<div class="settings">
  <section>
    <h3>Input Mode</h3>
    <div class="button-group">
      <button
        class:active={config.mode === 'trackpad'}
        on:click={() => setMode('trackpad')}
      >
        Trackpad
      </button>
      <button
        class:active={config.mode === 'trackball'}
        on:click={() => setMode('trackball')}
      >
        Trackball
      </button>
    </div>
  </section>

  <section>
    <h3>Hand</h3>
    <div class="button-group">
      <button
        class:active={config.hand === 'right'}
        on:click={() => { config.hand = 'right'; save(); }}
      >
        Right
      </button>
      <button
        class:active={config.hand === 'left'}
        on:click={() => { config.hand = 'left'; save(); }}
      >
        Left
      </button>
    </div>
  </section>

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

  {#if config.mode === 'trackball'}
    <section>
      <h3>Friction <span class="value">{Math.round(config.trackball_friction * 100)}%</span></h3>
      <input
        type="range"
        min="0.85"
        max="0.99"
        step="0.01"
        bind:value={config.trackball_friction}
        on:change={save}
      />
      <small>Higher = longer coasting</small>
    </section>
  {/if}

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

  .button-group {
    display: flex;
    gap: 8px;
  }

  .button-group button {
    flex: 1;
    padding: 8px;
    border: 1px solid #ddd;
    border-radius: 8px;
    background: white;
    cursor: pointer;
    font-size: 14px;
    transition: all 0.15s;
    color: #1a1a1a;
  }
  :global(html[data-theme="dark"]) .button-group button {
    background: #2c2c2e;
    border-color: #48484a;
    color: #f2f2f7;
  }

  .button-group button.active {
    background: #007aff;
    color: white;
    border-color: #007aff;
  }
  :global(html[data-theme="dark"]) .button-group button.active {
    background: #0a84ff;
    color: #ffffff;
    border-color: #5ac8fa;
    box-shadow: 0 0 0 1px rgba(90, 200, 250, 0.35);
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
</style>
