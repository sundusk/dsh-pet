/**
 * dsh-mac-pet host plugin — a Harness status bridge (no rendered browser UI, no
 * settings namespace) that tracks agent activity, serves a stable snapshot over
 * HTTP and a local Unix socket, and queues Session-open requests for the tiny
 * browser half.
 * Install
 * via `dsh plugin --profile web add dsh-mac-pet`.
 * @module dsh-mac-pet
 */
import { Context } from '@deepseek-ai/cordis';
export { CommandBridge } from './CommandBridge.js';
export { LocalStateBridge } from './LocalStateBridge.js';
export { createHarnessInstanceDescriptor, HarnessInstanceManifest, instanceDiscoveryDirectory, instanceManifestPath, refreshHarnessInstanceWebURL, } from './HarnessInstance.js';
export type { HarnessInstanceDescriptor, HarnessInstanceKind } from './HarnessInstance.js';
/** Stable cordis plugin name (matches cordis.patch.yml insert id). */
export declare const name = "dsh-pet";
/** Services required before the status surface can mount. */
export declare const inject: string[];
/** The mood the desktop app renders (same vocabulary as the web water ball). */
export type DshPetMood = 'idle' | 'waiting' | 'jumping' | 'done' | 'failed' | 'stopped' | 'waving' | 'authorizing' | 'questioning';
/**
 * Register the DSH Pet status surface: fold the agent session stream into a
 * stable snapshot, serve it over GET /api/dsh-pet/status, and broadcast the
 * same snapshot through LocalStateBridge. The route is always live while the
 * plugin is loaded — there is no settings namespace to toggle.
 * @param ctx - host root context.
 */
export declare function apply(ctx: Context): void;
