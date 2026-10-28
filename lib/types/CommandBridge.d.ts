import type { PromptContentPart } from '@deepseek-ai/dsh-api-session-controller';
import type { MoodBridgePayload } from './LocalStateBridge.js';
import type { HarnessInstanceDescriptor } from './HarnessInstance.js';
type PromptImageMediaType = Extract<PromptContentPart, {
    type: 'image';
}>['mediaType'];
/** A detached workspace projection exposed to DSH Pet.app. */
export interface DshPetWorkspace {
    id: string;
    title: string;
    path: string;
    status: 'ok' | 'missing-dir';
    sessionIds: readonly string[];
}
export interface CreateSessionCommand {
    workspaceId: string;
    sessionId: string;
}
export interface PromptCommand {
    workspaceId: string;
    sessionId: string;
    requestId: string;
    text: string;
    images: readonly PromptImage[];
}
export interface PromptImage {
    mediaType: PromptImageMediaType;
    data: string;
    name?: string;
}
/** Deployment-resolved image admission policy exposed by Harness. */
export interface ImageAttachmentLimits {
    maxImageBytes: number;
    maxImagesPerMessage: number;
    maxMessageImageBytes: number;
    maxImagePixels: number;
    maxImageDimension: number;
    mediaTypes: readonly string[];
}
/** A cold-safe ordinary Session projection for the task cards. */
export interface DshPetTask {
    sessionId: string;
    workspaceId: string;
    title: string;
    cwd?: string;
    updatedAt: number;
    running: boolean;
    blank: boolean;
    state: 'disconnected' | 'idle' | 'thinking' | 'toolCalling' | 'waitingApproval' | 'waitingUserAnswer' | 'completed' | 'failed' | 'stopped';
    mood: string;
    taskRunning: boolean;
    waitingForUser: boolean;
    failed: boolean;
    completed: boolean;
    tool?: string;
    message?: string;
}
export interface CommandHandlers {
    imageAttachmentLimits: ImageAttachmentLimits;
    listWorkspaces: () => Promise<readonly DshPetWorkspace[]>;
    listTasks: () => Promise<readonly DshPetTask[]>;
    createSession: (request: CreateSessionCommand) => Promise<{
        sessionId: string;
    }>;
    prompt: (request: PromptCommand) => Promise<{
        accepted: true;
        sessionId: string;
    }>;
    snapshotFor: (sessionId: string) => MoodBridgePayload | undefined;
}
/**
 * User-local command and session-status transport.
 *
 * This socket is intentionally separate from LocalStateBridge. Older DSH Pet
 * clients continue to receive the global read-only snapshot, while new
 * clients can issue authenticated-by-file-permission commands and subscribe
 * to one selected session without mixing command responses into that stream.
 */
export declare class CommandBridge {
    static defaultPath: string;
    private readonly socketPath;
    private readonly handlers;
    private readonly instance;
    private readonly maxCommandBytes;
    private server;
    private ownsSocket;
    private clients;
    private probeGeneration;
    private probing;
    private socketIdentity;
    constructor(handlers: CommandHandlers, socketPath?: string, instance?: HarnessInstanceDescriptor);
    start(onReady?: () => void): void;
    private listen;
    /** Push a replacement snapshot to clients subscribed to this session. */
    publish(sessionId: string, snapshot: MoodBridgePayload): void;
    /** Push a replacement task projection to clients that requested task updates. */
    publishTasks(tasks: readonly DshPetTask[]): void;
    stop(): void;
    private consume;
    private rejectOversizedRequest;
    private handle;
    private respond;
    private write;
}
export {};
