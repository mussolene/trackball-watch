import { writable } from 'svelte/store';

export interface AppConfig {
  sensitivity: number;
  accel: {
    curve: 's_curve' | 'linear' | 'quadratic';
    sensitivity: number;
    knee_point: number;
    max_delta: number;
  };
  trackball_friction: number;
  udp_port: number;
  start_minimized: boolean;
  start_on_login: boolean;
}

export const config = writable<AppConfig | null>(null);
export const connectionStatus = writable<'disconnected' | 'connecting' | 'connected'>('disconnected');
