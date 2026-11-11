import { type Socket } from 'node:net';
export interface UnixSocketServerOptions {
    socketPath: string;
    /** Used in diagnostics: "command bridge" or "local bridge". */
    label: string;
    onConnection: (socket: Socket) => void;
    onStop: () => void;
}
/**
 * Owns one user-local Unix socket with stale-owner probing and replacement
 * protection. Both the command channel and the read-only status channel use
 * the same lifecycle rules; their client protocols stay in their own classes.
 */
export declare class UnixSocketServer {
    private readonly socketPath;
    private readonly label;
    private readonly onConnection;
    private readonly onStop;
    private server;
    private ownsSocket;
    private probeGeneration;
    private probing;
    private socketIdentity;
    constructor(options: UnixSocketServerOptions);
    start(onReady?: () => void): void;
    stop(): void;
    private listen;
}
