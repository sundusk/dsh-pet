export type HarnessInstanceKind = 'desktop' | 'web' | 'unknown';
/** The on-disk discovery contract consumed by DSH Pet.app. */
export interface HarnessInstanceDescriptor {
    protocolVersion: 1;
    instanceId: string;
    kind: HarnessInstanceKind;
    profile?: string;
    /** Stable hash of a known Harness profile/home target; never the raw path. */
    targetId?: string;
    pid: number;
    startedAt: number;
    webURL?: string;
    statusSocketPath: string;
    commandSocketPath: string;
}
export declare const INSTANCE_PROTOCOL_VERSION: 1;
/**
 * Build a per-plugin identity. The plugin gets no reliable process-name based
 * signal, so kind stays unknown unless the host supplies an explicit profile or
 * kind. This avoids presenting a guessed Desktop/Web label in the settings UI.
 */
export declare function createHarnessInstanceDescriptor(context?: unknown): HarnessInstanceDescriptor;
/** Refresh the origin after WebServer has finished listening. */
export declare function refreshHarnessInstanceWebURL(descriptor: HarnessInstanceDescriptor, context?: unknown): boolean;
/** The default discovery directory shared by Desktop and Web Harness hosts. */
export declare function instanceDiscoveryDirectory(home?: string): string;
export declare function instanceManifestPath(instanceId: string, home?: string): string;
/** Publishes and removes only the manifest belonging to one generated identity. */
export declare class HarnessInstanceManifest {
    private readonly descriptor;
    private readonly directory;
    private published;
    constructor(descriptor: HarnessInstanceDescriptor, directory?: string);
    get path(): string;
    publish(): void;
    remove(): void;
}
