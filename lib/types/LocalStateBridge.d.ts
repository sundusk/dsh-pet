/** The newline-delimited local bridge payload shared with DSH Pet.app. */
export interface MoodBridgePayload {
    instanceId?: string;
    state: string;
    mood: string;
    sessionId?: string;
    workspaceId?: string;
    taskRunning: boolean;
    waitingForUser: boolean;
    failed: boolean;
    completed: boolean;
    tool?: string;
    message?: string;
    updatedAt: number;
}
/**
 * Small, opt-in local transport for the host plugin.
 *
 * The socket is deliberately a server owned by the plugin: DSH Pet only
 * observes it and never starts or stops Harness. Each client receives the
 * latest snapshot immediately, then one JSON object per line on change.
 */
export declare class LocalStateBridge {
    private readonly readSnapshot;
    private readonly socketServer;
    private clients;
    constructor(readSnapshot: () => MoodBridgePayload, socketPath: string);
    start(onReady?: () => void): void;
    publish(): void;
    stop(): void;
    private write;
}
