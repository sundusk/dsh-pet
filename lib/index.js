import { basename, dirname, join } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { connect, createServer } from "node:net";
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
//#region src/CommandBridge.ts
const COMMAND_METADATA_BYTES = 1048576;
var CommandError = class extends Error {
	code;
	constructor(code, message) {
		super(message);
		this.code = code;
		this.name = "CommandError";
	}
};
/**
* User-local command and session-status transport.
*
* This socket is intentionally separate from LocalStateBridge. Older DSH Pet
* clients continue to receive the global read-only snapshot, while new
* clients can issue authenticated-by-file-permission commands and subscribe
* to one selected session without mixing command responses into that stream.
*/
var CommandBridge = class CommandBridge {
	static defaultPath = join(homedir(), "Library", "Application Support", "DSH Pet", "dsh-pet-command.sock");
	socketPath;
	handlers;
	instance;
	maxCommandBytes;
	server;
	ownsSocket = false;
	clients = /* @__PURE__ */ new Set();
	probeGeneration = 0;
	probing = false;
	socketIdentity;
	constructor(handlers, socketPath = process.env.DSH_PET_COMMAND_SOCKET_PATH ?? process.env.MOODBALL_COMMAND_SOCKET_PATH ?? CommandBridge.defaultPath, instance) {
		this.handlers = handlers;
		this.instance = instance;
		this.socketPath = socketPath;
		this.maxCommandBytes = maxCommandBytes(handlers.imageAttachmentLimits);
	}
	start(onReady) {
		if (this.server || this.probing) return;
		mkdirSync(dirname(this.socketPath), { recursive: true });
		if (existsSync(this.socketPath)) {
			if (!lstatSync(this.socketPath).isSocket()) {
				console.warn(`[dsh-pet] command bridge path is not a socket: ${this.socketPath}`);
				return;
			}
			const staleIdentity = socketIdentity$1(this.socketPath);
			const generation = ++this.probeGeneration;
			this.probing = true;
			const probe = connect(this.socketPath);
			probe.once("connect", () => {
				probe.destroy();
				this.probing = false;
				console.warn(`[dsh-pet] command bridge path is already active: ${this.socketPath}`);
			});
			probe.once("error", (error) => {
				probe.destroy();
				this.probing = false;
				if (generation !== this.probeGeneration) return;
				const code = "code" in error ? error.code : void 0;
				if (code !== "ECONNREFUSED" && code !== "ENOENT") {
					console.warn(`[dsh-pet] command bridge unavailable: ${error.message}`);
					return;
				}
				if (!sameSocketIdentity$1(staleIdentity, socketIdentity$1(this.socketPath))) return;
				try {
					unlinkSync(this.socketPath);
				} catch {}
				this.listen(onReady);
			});
			return;
		}
		this.listen(onReady);
	}
	listen(onReady) {
		const generation = this.probeGeneration;
		const server = createServer((socket) => {
			const client = {
				socket,
				buffer: "",
				bufferBytes: 0,
				discardingOversizedLine: false,
				subscriptions: /* @__PURE__ */ new Set(),
				taskSubscription: false,
				operationTail: Promise.resolve()
			};
			this.clients.add(client);
			socket.setNoDelay(true);
			socket.setEncoding("utf8");
			socket.on("data", (chunk) => {
				let text = String(chunk);
				if (client.discardingOversizedLine) {
					const newline = text.indexOf("\n");
					if (newline < 0) return;
					client.discardingOversizedLine = false;
					text = text.slice(newline + 1);
				}
				client.buffer += text;
				client.bufferBytes += Buffer.byteLength(text);
				this.consume(client);
			});
			socket.on("close", () => this.clients.delete(client));
			socket.on("error", () => this.clients.delete(client));
		});
		server.on("error", (error) => {
			console.warn(`[dsh-pet] command bridge unavailable: ${error.message}`);
		});
		server.listen(this.socketPath, () => {
			const identity = socketIdentity$1(this.socketPath);
			if (generation !== this.probeGeneration) {
				server.close();
				unlinkIfSame$1(this.socketPath, identity);
				return;
			}
			this.ownsSocket = true;
			this.socketIdentity = identity;
			try {
				chmodSync(this.socketPath, 384);
			} catch {}
			onReady?.();
		});
		this.server = server;
	}
	/** Push a replacement snapshot to clients subscribed to this session. */
	publish(sessionId, snapshot) {
		for (const client of this.clients) {
			if (!client.subscriptions.has(sessionId)) continue;
			this.write(client.socket, {
				event: "status",
				sessionId,
				snapshot
			});
		}
	}
	/** Push a replacement task projection to clients that requested task updates. */
	publishTasks(tasks) {
		for (const client of this.clients) {
			if (!client.taskSubscription) continue;
			this.write(client.socket, {
				event: "tasks",
				tasks
			});
		}
	}
	stop() {
		this.probeGeneration += 1;
		this.probing = false;
		for (const client of this.clients) client.socket.destroy();
		this.clients.clear();
		const server = this.server;
		this.server = void 0;
		if (!server) return;
		const replacement = preserveReplacement$1(this.socketPath, this.socketIdentity);
		server.close();
		if (replacement !== void 0) try {
			renameSync(replacement, this.socketPath);
		} catch {}
		else if (this.ownsSocket) unlinkIfSame$1(this.socketPath, this.socketIdentity);
		this.ownsSocket = false;
		this.socketIdentity = void 0;
	}
	consume(client) {
		while (true) {
			const newline = client.buffer.indexOf("\n");
			if (newline < 0) {
				if (client.bufferBytes > this.maxCommandBytes) {
					client.buffer = "";
					client.bufferBytes = 0;
					client.discardingOversizedLine = true;
					this.rejectOversizedRequest(client.socket);
				}
				return;
			}
			const line = client.buffer.slice(0, newline);
			client.buffer = client.buffer.slice(newline + 1);
			client.bufferBytes -= Buffer.byteLength(`${line}\n`);
			if (line.trim() === "") continue;
			if (Buffer.byteLength(line) > this.maxCommandBytes) {
				this.rejectOversizedRequest(client.socket);
				continue;
			}
			client.operationTail = client.operationTail.then(() => this.handle(client, line)).catch((error) => {
				this.write(client.socket, {
					id: null,
					ok: false,
					error: {
						code: "internal-error",
						message: errorMessage(error)
					}
				});
			});
		}
	}
	rejectOversizedRequest(socket) {
		this.write(socket, {
			id: null,
			ok: false,
			error: {
				code: "request-too-large",
				message: "command request exceeds the deployment image limits"
			}
		});
	}
	async handle(client, line) {
		let request;
		try {
			request = JSON.parse(line);
		} catch {
			this.write(client.socket, {
				id: null,
				ok: false,
				error: {
					code: "invalid-json",
					message: "request must be one JSON object per line"
				}
			});
			return;
		}
		const id = typeof request.id === "string" && request.id !== "" ? request.id : null;
		const action = request.action;
		try {
			if (action === "capabilities") {
				this.respond(client.socket, id, {
					protocolVersion: 1,
					commandSocket: true,
					statusSubscription: true,
					supports: [
						"workspaces",
						"tasks",
						"subscribeTasks",
						"unsubscribeTasks",
						"createSession",
						"prompt",
						"imageAttachments",
						"subscribe",
						"unsubscribe"
					],
					attachmentLimits: this.handlers.imageAttachmentLimits,
					maxCommandBytes: this.maxCommandBytes,
					...this.instance === void 0 ? {} : { instance: this.instance }
				});
				return;
			}
			if (action === "workspaces") {
				this.respond(client.socket, id, { workspaces: await this.handlers.listWorkspaces() });
				return;
			}
			if (action === "tasks") {
				this.respond(client.socket, id, { tasks: await this.handlers.listTasks() });
				return;
			}
			if (action === "subscribeTasks") {
				client.taskSubscription = true;
				this.respond(client.socket, id, { tasks: await this.handlers.listTasks() });
				return;
			}
			if (action === "unsubscribeTasks") {
				client.taskSubscription = false;
				this.respond(client.socket, id, {});
				return;
			}
			if (action === "createSession") {
				const workspaceId = stringField(request.workspaceId, "workspaceId");
				const sessionId = stringField(request.sessionId, "sessionId");
				const result = await this.handlers.createSession({
					workspaceId,
					sessionId
				});
				this.respond(client.socket, id, result);
				return;
			}
			if (action === "prompt") {
				const workspaceId = stringField(request.workspaceId, "workspaceId");
				const sessionId = stringField(request.sessionId, "sessionId");
				const requestId = stringField(request.requestId, "requestId");
				const text = optionalStringField(request.text, "text") ?? "";
				const images = imageFields(request.images, this.handlers.imageAttachmentLimits);
				if (text.trim() === "" && images.length === 0) throw new CommandError("empty-prompt", "prompt must include non-whitespace text or an image");
				const result = await this.handlers.prompt({
					workspaceId,
					sessionId,
					requestId,
					text,
					images
				});
				this.respond(client.socket, id, result);
				return;
			}
			if (action === "subscribe") {
				const sessionId = stringField(request.sessionId, "sessionId");
				client.subscriptions.add(sessionId);
				this.respond(client.socket, id, {
					sessionId,
					snapshot: this.handlers.snapshotFor(sessionId) ?? null
				});
				return;
			}
			if (action === "unsubscribe") {
				const sessionId = stringField(request.sessionId, "sessionId");
				client.subscriptions.delete(sessionId);
				this.respond(client.socket, id, { sessionId });
				return;
			}
			throw new CommandError("unknown-action", "unsupported DSH Pet command");
		} catch (error) {
			this.write(client.socket, {
				id,
				ok: false,
				error: {
					code: commandErrorCode(error),
					message: errorMessage(error)
				}
			});
		}
	}
	respond(socket, id, result) {
		this.write(socket, {
			id,
			ok: true,
			...asObject(result)
		});
	}
	write(socket, payload) {
		if (!socket.destroyed) socket.write(`${JSON.stringify(payload)}\n`);
	}
};
function socketIdentity$1(path) {
	try {
		const stat = lstatSync(path);
		return stat.isSocket() ? {
			dev: stat.dev,
			ino: stat.ino
		} : void 0;
	} catch {
		return;
	}
}
function sameSocketIdentity$1(left, right) {
	return left !== void 0 && right !== void 0 && left.dev === right.dev && left.ino === right.ino;
}
function unlinkIfSame$1(path, identity) {
	if (!sameSocketIdentity$1(identity, socketIdentity$1(path))) return;
	try {
		unlinkSync(path);
	} catch {}
}
function preserveReplacement$1(path, owner) {
	if (owner === void 0) return void 0;
	const current = socketIdentity$1(path);
	if (sameSocketIdentity$1(owner, current) || current === void 0) return void 0;
	const backup = `${path}.dsh-pet-preserve-${randomUUID()}`;
	try {
		renameSync(path, backup);
		return backup;
	} catch {
		return;
	}
}
function stringField(value, name) {
	if (typeof value !== "string" || value.trim() === "") throw new CommandError("invalid-request", `${name} must be a non-empty string`);
	return value;
}
function optionalStringField(value, name) {
	if (value === void 0) return void 0;
	if (typeof value !== "string") throw new CommandError("invalid-request", `${name} must be a string`);
	return value;
}
function imageFields(value, limits) {
	if (value === void 0) return [];
	if (!Array.isArray(value)) throw new CommandError("invalid-request", "images must be an array");
	if (value.length > limits.maxImagesPerMessage) throw new CommandError("session/attachment-invalid", "Image batch exceeds the configured image-count limit.");
	let aggregateBytes = 0;
	return value.map((candidate, index) => {
		if (candidate === null || typeof candidate !== "object" || Array.isArray(candidate)) throw new CommandError("invalid-request", `images[${index}] must be an object`);
		const image = candidate;
		const mediaType = stringField(image.mediaType, `images[${index}].mediaType`);
		if (!limits.mediaTypes.includes(mediaType)) throw new CommandError("session/attachment-invalid", `Image type ${mediaType} is not accepted by this deployment.`);
		const data = stringField(image.data, `images[${index}].data`);
		const name = optionalStringField(image.name, `images[${index}].name`);
		const bytes = canonicalBase64Bytes(data);
		if (bytes > limits.maxImageBytes) throw new CommandError("session/attachment-invalid", "Image exceeds the configured image-byte limit.");
		aggregateBytes += bytes;
		if (aggregateBytes > limits.maxMessageImageBytes) throw new CommandError("session/attachment-invalid", "Image batch exceeds the configured aggregate image-byte limit.");
		return {
			mediaType,
			data,
			...name === void 0 ? {} : { name }
		};
	});
}
function canonicalBase64Bytes(data) {
	if (data.length === 0 || data.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)) throw new CommandError("session/attachment-invalid", "Image upload is not canonical base64.");
	const padding = data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0;
	return data.length / 4 * 3 - padding;
}
function maxCommandBytes(limits) {
	const aggregateBytes = Math.min(limits.maxMessageImageBytes, limits.maxImageBytes * limits.maxImagesPerMessage);
	const base64Bytes = Math.ceil(aggregateBytes / 3) * 4;
	return Math.min(Number.MAX_SAFE_INTEGER, base64Bytes + COMMAND_METADATA_BYTES);
}
function commandErrorCode(error) {
	if (error instanceof CommandError) return error.code;
	if (error !== null && typeof error === "object" && "code" in error) {
		const code = error.code;
		if (typeof code === "string" && code !== "") return code;
	}
	return "command-failed";
}
function asObject(value) {
	if (value !== null && typeof value === "object" && !Array.isArray(value)) return value;
	return { value };
}
function errorMessage(error) {
	return error instanceof Error ? error.message : String(error);
}
//#endregion
//#region src/LocalStateBridge.ts
/**
* Small, opt-in local transport for the host plugin.
*
* The socket is deliberately a server owned by the plugin: DSH Pet only
* observes it and never starts or stops Harness. Each client receives the
* latest snapshot immediately, then one JSON object per line on change.
*/
var LocalStateBridge = class LocalStateBridge {
	static defaultPath = join(homedir(), "Library", "Application Support", "DSH Pet", "dsh-pet.sock");
	socketPath;
	readSnapshot;
	server;
	clients = /* @__PURE__ */ new Set();
	ownsSocket = false;
	probeGeneration = 0;
	probing = false;
	socketIdentity;
	constructor(readSnapshot, socketPath = process.env.DSH_PET_SOCKET_PATH ?? process.env.MOODBALL_SOCKET_PATH ?? LocalStateBridge.defaultPath) {
		this.readSnapshot = readSnapshot;
		this.socketPath = socketPath;
	}
	start(onReady) {
		if (this.server || this.probing) return;
		mkdirSync(dirname(this.socketPath), { recursive: true });
		if (existsSync(this.socketPath)) {
			if (!lstatSync(this.socketPath).isSocket()) {
				console.warn(`[dsh-pet] local bridge path is not a socket: ${this.socketPath}`);
				return;
			}
			const staleIdentity = socketIdentity(this.socketPath);
			const generation = ++this.probeGeneration;
			this.probing = true;
			const probe = connect(this.socketPath);
			probe.once("connect", () => {
				probe.destroy();
				this.probing = false;
				console.warn(`[dsh-pet] local bridge path is already active: ${this.socketPath}`);
			});
			probe.once("error", (error) => {
				probe.destroy();
				this.probing = false;
				if (generation !== this.probeGeneration) return;
				const code = "code" in error ? error.code : void 0;
				if (code !== "ECONNREFUSED" && code !== "ENOENT") {
					console.warn(`[dsh-pet] local bridge unavailable: ${error.message}`);
					return;
				}
				if (!sameSocketIdentity(staleIdentity, socketIdentity(this.socketPath))) return;
				try {
					unlinkSync(this.socketPath);
				} catch {}
				this.listen(onReady);
			});
			return;
		}
		this.listen(onReady);
	}
	listen(onReady) {
		const generation = this.probeGeneration;
		const server = createServer((client) => {
			this.clients.add(client);
			client.setNoDelay(true);
			client.on("close", () => this.clients.delete(client));
			client.on("error", () => this.clients.delete(client));
			this.write(client);
		});
		server.on("error", (error) => {
			console.warn(`[dsh-pet] local bridge unavailable: ${error.message}`);
		});
		server.listen(this.socketPath, () => {
			const identity = socketIdentity(this.socketPath);
			if (generation !== this.probeGeneration) {
				server.close();
				unlinkIfSame(this.socketPath, identity);
				return;
			}
			this.ownsSocket = true;
			this.socketIdentity = identity;
			try {
				chmodSync(this.socketPath, 384);
			} catch {}
			onReady?.();
		});
		this.server = server;
	}
	publish() {
		for (const client of this.clients) this.write(client);
	}
	stop() {
		this.probeGeneration += 1;
		this.probing = false;
		for (const client of this.clients) client.destroy();
		this.clients.clear();
		const server = this.server;
		this.server = void 0;
		if (!server) return;
		const replacement = preserveReplacement(this.socketPath, this.socketIdentity);
		server.close();
		if (replacement !== void 0) try {
			renameSync(replacement, this.socketPath);
		} catch {}
		else if (this.ownsSocket) unlinkIfSame(this.socketPath, this.socketIdentity);
		this.ownsSocket = false;
		this.socketIdentity = void 0;
	}
	write(client) {
		if (!client.destroyed) client.write(`${JSON.stringify(this.readSnapshot())}\n`);
	}
};
function socketIdentity(path) {
	try {
		const stat = lstatSync(path);
		return stat.isSocket() ? {
			dev: stat.dev,
			ino: stat.ino
		} : void 0;
	} catch {
		return;
	}
}
function sameSocketIdentity(left, right) {
	return left !== void 0 && right !== void 0 && left.dev === right.dev && left.ino === right.ino;
}
function unlinkIfSame(path, identity) {
	if (!sameSocketIdentity(identity, socketIdentity(path))) return;
	try {
		unlinkSync(path);
	} catch {}
}
function preserveReplacement(path, owner) {
	if (owner === void 0) return void 0;
	const current = socketIdentity(path);
	if (sameSocketIdentity(owner, current) || current === void 0) return void 0;
	const backup = `${path}.dsh-pet-preserve-${randomUUID()}`;
	try {
		renameSync(path, backup);
		return backup;
	} catch {
		return;
	}
}
const MAX_UNIX_SOCKET_PATH_BYTES = 103;
/**
* Build a per-plugin identity. The plugin gets no reliable process-name based
* signal, so kind stays unknown unless the host supplies an explicit profile or
* kind. This avoids presenting a guessed Desktop/Web label in the settings UI.
*/
function createHarnessInstanceDescriptor(context) {
	const hints = context;
	const profileContext = readHint(hints, "profileContext");
	const resolvedProfile = readHint(hints, "resolvedProfile");
	const profile = firstNonEmptyString(process.env.DSH_PET_PROFILE, process.env.MOODBALL_PROFILE, process.env.DSH_PROFILE, profileContext?.name, readHint(hints, "profile"), resolvedProfile?.profile, profileFromArgv()) ?? profileName(resolvedProfile?.profile);
	const kind = normalizeKind(firstNonEmptyString(process.env.DSH_PET_HARNESS_KIND, process.env.MOODBALL_HARNESS_KIND, process.env.DSH_PET_HARNESS_TYPE, process.env.MOODBALL_HARNESS_TYPE, readHint(hints, "kind"), readHint(hints, "type"), readServiceString(hints, "harnessKind"))) ?? (profile === "desktop" ? "desktop" : profile === "web" ? "web" : "unknown");
	const instanceId = randomUUID().replaceAll("-", "").slice(0, 12);
	const uid = typeof process.getuid === "function" ? process.getuid() : process.pid;
	const socketDir = join("/tmp", `dsh-pet-${uid}`);
	mkdirSync(socketDir, {
		recursive: true,
		mode: 448
	});
	chmodSync(socketDir, 448);
	const statusSocketPath = join(socketDir, `${instanceId}-s.sock`);
	const commandSocketPath = join(socketDir, `${instanceId}-c.sock`);
	assertSocketPath(statusSocketPath);
	assertSocketPath(commandSocketPath);
	const webURL = safeLoopbackURL(process.env.DSH_PET_WEB_URL ?? process.env.MOODBALL_WEB_URL ?? process.env.DSH_WEB_URL ?? contextOrigin(hints) ?? contextWebURL(hints));
	const targetId = targetIdentity(profile, hints);
	return {
		protocolVersion: 1,
		instanceId,
		kind,
		...profile === void 0 ? {} : { profile },
		...targetId === void 0 ? {} : { targetId },
		pid: process.pid,
		startedAt: Math.floor(Date.now() / 1e3),
		...webURL === void 0 ? {} : { webURL },
		statusSocketPath,
		commandSocketPath
	};
}
/** Refresh the origin after WebServer has finished listening. */
function refreshHarnessInstanceWebURL(descriptor, context) {
	const hints = context;
	const webURL = safeLoopbackURL(contextOrigin(hints) ?? contextWebURL(hints));
	if (webURL === void 0) return false;
	descriptor.webURL = webURL;
	return true;
}
/** The default discovery directory shared by Desktop and Web Harness hosts. */
function instanceDiscoveryDirectory(home = homedir()) {
	return join(home, "Library", "Application Support", "DSH Pet", "instances");
}
function instanceManifestPath(instanceId, home = homedir()) {
	return join(instanceDiscoveryDirectory(home), `${instanceId}.json`);
}
/** Publishes and removes only the manifest belonging to one generated identity. */
var HarnessInstanceManifest = class {
	descriptor;
	directory;
	published = false;
	constructor(descriptor, directory = instanceDiscoveryDirectory()) {
		this.descriptor = descriptor;
		this.directory = directory;
	}
	get path() {
		return join(this.directory, `${this.descriptor.instanceId}.json`);
	}
	publish() {
		mkdirSync(this.directory, {
			recursive: true,
			mode: 448
		});
		const temporary = `${this.path}.${process.pid}.${randomUUID()}.tmp`;
		writeFileSync(temporary, `${JSON.stringify(this.descriptor)}\n`, { mode: 384 });
		chmodSync(temporary, 384);
		renameSync(temporary, this.path);
		chmodSync(this.path, 384);
		this.published = true;
	}
	remove() {
		if (!this.published || !existsSync(this.path)) return;
		try {
			if (JSON.parse(readFileSync(this.path, "utf8")).instanceId !== this.descriptor.instanceId) return;
			unlinkSync(this.path);
			this.published = false;
		} catch {}
	}
};
function firstNonEmptyString(...values) {
	return values.find((value) => typeof value === "string" && value.trim() !== "");
}
function normalizeKind(value) {
	if (value === "desktop" || value === "web" || value === "unknown") return value;
}
function readHint(context, name) {
	try {
		return context?.get?.(name, false) ?? context?.[name];
	} catch {
		return;
	}
}
function readServiceString(context, name) {
	try {
		return context?.get?.(name, false);
	} catch {
		return;
	}
}
function profileFromArgv() {
	const args = process.argv.slice(1);
	const flag = args.indexOf("--profile");
	const value = flag >= 0 ? args[flag + 1] : void 0;
	return value !== void 0 && value !== "" && !value.startsWith("-") ? value : void 0;
}
function contextOrigin(context) {
	try {
		return readHint(context, "webServer")?.getOrigin?.();
	} catch {
		return;
	}
}
function contextWebURL(context) {
	const server = readHint(context, "webServer");
	if (server === void 0) return void 0;
	const protocol = typeof server.protocol === "string" ? server.protocol : void 0;
	const host = firstNonEmptyString(server.host, server.hostname);
	const port = typeof server.port === "number" && Number.isInteger(server.port) ? server.port : void 0;
	if (protocol === void 0 || host === void 0 || port === void 0) return void 0;
	return `${protocol}//${host}:${port}`;
}
function profileName(value) {
	if (value === null || typeof value !== "object") return void 0;
	const name = value.name;
	return typeof name === "string" && name.trim() !== "" ? name : void 0;
}
function targetIdentity(profile, context) {
	const explicit = firstNonEmptyString(process.env.DSH_PET_TARGET_ID, process.env.MOODBALL_TARGET_ID, readServiceString(context, "targetId"));
	if (explicit !== void 0) return explicit;
	const profileContext = readHint(context, "profileContext");
	const profileObject = readHint(context, "resolvedProfile")?.profile;
	const profileDir = firstNonEmptyString(profileContext?.dir, readHint(context, "profileDir"), profileObject !== null && typeof profileObject === "object" ? profileObject.dir : void 0);
	const home = firstNonEmptyString(process.env.DSH_HOME, profileContext?.home, readHint(context, "home"));
	const source = profileDir ?? (home !== void 0 && profile !== void 0 ? `${home}\u0000${profile}` : void 0);
	if (source === void 0) return void 0;
	return `target-${createHash("sha256").update(source).digest("hex").slice(0, 16)}`;
}
function safeLoopbackURL(value) {
	if (value === void 0) return void 0;
	try {
		const url = new URL(value);
		if (!["http:", "https:"].includes(url.protocol)) return void 0;
		if (![
			"127.0.0.1",
			"localhost",
			"[::1]",
			"::1"
		].includes(url.hostname)) return void 0;
		if (url.username !== "" || url.password !== "" || url.search !== "" || url.hash !== "") return void 0;
		if (url.pathname !== "" && url.pathname !== "/") return void 0;
		return url.origin;
	} catch {
		return;
	}
}
function assertSocketPath(path) {
	if (Buffer.byteLength(path) > MAX_UNIX_SOCKET_PATH_BYTES) throw new Error(`DSH Pet instance socket path exceeds Unix limit: ${path}`);
}
//#endregion
//#region src/index.ts
/** Stable cordis plugin name (matches cordis.patch.yml insert id). */
const name = "dsh-pet";
/** Services required before the status surface can mount. */
const inject = [
	"webServer",
	"workspaceRegistry",
	"sessionController",
	"attachments"
];
function stateForMood(mood) {
	switch (mood) {
		case "waiting": return "thinking";
		case "jumping": return "toolCalling";
		case "authorizing": return "waitingApproval";
		case "questioning": return "waitingUserAnswer";
		case "done": return "completed";
		case "failed": return "failed";
		case "stopped": return "stopped";
		case "idle": return "idle";
		default: return "disconnected";
	}
}
function isRunningMood(mood) {
	return [
		"waiting",
		"jumping",
		"authorizing",
		"questioning"
	].includes(mood);
}
/** Write one JSON response. */
function json(res, status, body) {
	res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
	res.end(JSON.stringify(body));
}
/**
* Register the DSH Pet status surface: fold the agent session stream into a
* stable snapshot, serve it over GET /api/dsh-pet/status, and broadcast the
* same snapshot through LocalStateBridge. The route is always live while the
* plugin is loaded — there is no settings namespace to toggle.
* @param ctx - host root context.
*/
function apply(ctx) {
	const globalState = {
		mood: "idle",
		holdUntil: 0,
		questionActive: false
	};
	const sessionStates = /* @__PURE__ */ new Map();
	const sessionOperations = /* @__PURE__ */ new Map();
	let taskSnapshot = [];
	let taskRefreshTimer;
	let refreshTaskSnapshot;
	let activeSessionId;
	let commandBridge;
	const instance = createHarnessInstanceDescriptor(ctx);
	const instanceManifest = new HarnessInstanceManifest(instance, process.env.DSH_PET_INSTANCE_DIRECTORY ?? process.env.MOODBALL_INSTANCE_DIRECTORY ?? instanceDiscoveryDirectory());
	let statusReady = false;
	let commandReady = false;
	let originRetryTimer;
	let instanceManifestPublished = false;
	const publishInstanceManifest = () => {
		if (!statusReady || !commandReady || instanceManifestPublished) return;
		const hasOriginGetter = typeof ctx.webServer?.getOrigin === "function";
		if (instance.kind === "web" && hasOriginGetter && !refreshHarnessInstanceWebURL(instance, ctx)) {
			originRetryTimer ??= setTimeout(() => {
				originRetryTimer = void 0;
				publishInstanceManifest();
			}, 100);
			return;
		}
		refreshHarnessInstanceWebURL(instance, ctx);
		try {
			instanceManifest.publish();
			instanceManifestPublished = true;
		} catch (error) {
			console.warn(`[dsh-pet] instance discovery unavailable: ${String(error)}`);
		}
	};
	const stateFor = (sessionId, workspaceId) => {
		const existing = sessionStates.get(sessionId);
		if (existing) {
			if (workspaceId) existing.workspaceId = workspaceId;
			return existing;
		}
		const created = {
			sessionId,
			workspaceId,
			mood: "idle",
			holdUntil: 0,
			questionActive: false
		};
		sessionStates.set(sessionId, created);
		return created;
	};
	const workspaceForSession = (sessionId) => {
		const workspace = ctx.workspaceRegistry.list().find((candidate) => candidate.sessionIds.some((candidateSessionId) => String(candidateSessionId) === sessionId));
		return workspace ? String(workspace.id) : void 0;
	};
	const snapshotOf = (state) => ({
		instanceId: instance.instanceId,
		state: stateForMood(state.mood),
		mood: state.mood,
		...state.sessionId ? { sessionId: state.sessionId } : {},
		...state.workspaceId ? { workspaceId: state.workspaceId } : {},
		taskRunning: [
			"waiting",
			"jumping",
			"authorizing",
			"questioning"
		].includes(state.mood),
		waitingForUser: state.mood === "authorizing" || state.mood === "questioning",
		failed: state.mood === "failed",
		completed: state.mood === "done",
		...state.tool ? { tool: state.tool } : {},
		...state.message ? { message: state.message } : {},
		updatedAt: Date.now()
	});
	const snapshotForSession = (sessionId) => snapshotOf(stateFor(sessionId, workspaceForSession(sessionId)));
	const snapshot = () => activeSessionId === void 0 ? snapshotOf(globalState) : snapshotForSession(activeSessionId);
	const localBridge = new LocalStateBridge(snapshot, instance.statusSocketPath);
	const workspaceForSummary = (sessionId) => ctx.workspaceRegistry.list().find((workspace) => workspace.sessionIds.some((candidate) => String(candidate) === sessionId));
	const titleForSummary = (summary, workspace) => {
		const serviceContext = ctx;
		const sessions = serviceContext.get?.("sessions", false);
		const titleService = serviceContext.get?.("sessionTitle", false);
		const liveSession = sessions?.get(summary.sessionId);
		const title = liveSession === void 0 ? void 0 : titleService?.get(liveSession)?.title;
		if (title !== void 0 && title.trim() !== "") return title;
		const directory = summary.cwd === void 0 ? "" : basename(summary.cwd);
		const suffix = summary.sessionId.slice(-8);
		return directory !== "" && directory !== workspace.title ? `${directory} · 会话 ${suffix}` : `会话 ${suffix}`;
	};
	const tasksFromSummaries = (summaries) => summaries.flatMap((summary) => {
		if (summary.parentSessionId !== void 0 || summary.origin === "subagent") return [];
		const workspace = workspaceForSummary(summary.sessionId);
		if (workspace === void 0) return [];
		const state = stateFor(summary.sessionId, String(workspace.id));
		let mood = state.mood;
		if (summary.running && !isRunningMood(mood)) mood = "waiting";
		if (!summary.running && isRunningMood(mood)) mood = "idle";
		if (!summary.running && state.lastResult !== void 0) mood = state.lastResult;
		const projected = snapshotOf({
			...state,
			mood,
			workspaceId: String(workspace.id)
		});
		return [{
			sessionId: summary.sessionId,
			workspaceId: String(workspace.id),
			title: titleForSummary(summary, workspace),
			...summary.cwd === void 0 ? {} : { cwd: summary.cwd },
			updatedAt: summary.updatedAt,
			running: summary.running,
			blank: summary.blank,
			state: projected.state,
			mood: projected.mood,
			taskRunning: summary.running || projected.taskRunning,
			waitingForUser: projected.waitingForUser,
			failed: projected.failed,
			completed: projected.completed,
			...projected.tool === void 0 ? {} : { tool: projected.tool },
			...projected.message === void 0 ? {} : { message: projected.message }
		}];
	});
	const scheduleTaskRefresh = () => {
		if (taskRefreshTimer !== void 0) return;
		taskRefreshTimer = setTimeout(() => {
			taskRefreshTimer = void 0;
			refreshTaskSnapshot?.().catch((error) => {
				console.warn(`[dsh-pet] task list refresh failed: ${String(error)}`);
			});
		}, 150);
	};
	const publish = (state) => {
		localBridge.publish();
		if (state.sessionId) commandBridge?.publish(state.sessionId, snapshotOf(state));
		scheduleTaskRefresh();
	};
	const setTransient = (state, next, ms) => {
		state.mood = next;
		if (next === "done" || next === "failed" || next === "stopped") state.lastResult = next;
		state.holdUntil = Date.now() + ms;
		publish(state);
		setTimeout(() => {
			if (state.mood === next) {
				state.mood = "idle";
				publish(state);
			}
		}, ms);
	};
	ctx.on("session/event", (_session, event) => {
		const info = _session;
		const sessionId = info.id ?? info.sessionId;
		const state = sessionId === void 0 ? globalState : stateFor(sessionId, info.workspaceId ?? workspaceForSession(sessionId));
		if (sessionId) activeSessionId = sessionId;
		if (event.type === "turn/start" || event.type === "step/start" || event.type === "assistant/chunk") {
			state.lastResult = void 0;
			state.mood = "waiting";
			state.holdUntil = 0;
			state.message = void 0;
		} else if (event.type === "tool/call") {
			state.lastResult = void 0;
			const call = event.data ?? {};
			state.tool = call.name;
			if (call.name === "ask_user_question") {
				state.questionActive = true;
				state.mood = "questioning";
				state.holdUntil = 0;
			} else {
				state.mood = "jumping";
				state.holdUntil = 0;
			}
		} else if (event.type === "tool/result") {
			const result = event.data ?? {};
			if (state.questionActive) {
				state.questionActive = false;
				if (result.error !== void 0) setTransient(state, "stopped", 1500);
				else {
					state.mood = "waiting";
					state.holdUntil = 0;
				}
			} else {
				state.mood = "waiting";
				state.holdUntil = 0;
			}
		} else if (event.type === "approval/asked") {
			state.lastResult = void 0;
			state.mood = "authorizing";
			state.holdUntil = 0;
		} else if (event.type === "approval/decided") {
			const payload = event.data ?? {};
			if (payload.result === "allowed-once") {
				state.lastResult = void 0;
				state.mood = "waiting";
				state.holdUntil = 0;
			} else if (payload.result === "rejected" || payload.result === "cancelled" || payload.result === "unavailable") setTransient(state, "failed", 3e3);
		} else if (event.type === "activity/status") {
			const payload = event.data ?? {};
			if (payload.phase === void 0) return;
			switch (payload.phase) {
				case "waiting":
				case "thinking":
					state.lastResult = void 0;
					state.mood = "waiting";
					state.holdUntil = 0;
					state.message = void 0;
					break;
				case "tool":
					if (state.questionActive) return;
					state.lastResult = void 0;
					state.mood = "jumping";
					state.holdUntil = 0;
					break;
				case "done":
					setTransient(state, "done", 2500);
					break;
				case "idle":
					if (Date.now() < state.holdUntil) return;
					state.mood = "idle";
					state.tool = void 0;
					state.message = void 0;
			}
		} else if (event.type === "turn/end") {
			state.questionActive = false;
			const kind = (event.data ?? {}).reason?.kind;
			if (kind === "error") setTransient(state, "failed", 3e3);
			else if (kind === "completed") setTransient(state, "done", 2500);
			else if (kind !== void 0) setTransient(state, "stopped", 3e3);
		}
		publish(state);
	});
	ctx.on("session/created", () => {
		scheduleTaskRefresh();
	});
	ctx.on("session/disposed", (session) => {
		sessionStates.delete(String(session.id));
		scheduleTaskRefresh();
	});
	const serializeSession = (sessionId, operation) => {
		const result = (sessionOperations.get(sessionId) ?? Promise.resolve()).then(operation);
		const settled = result.then(() => void 0, () => void 0);
		sessionOperations.set(sessionId, settled);
		settled.then(() => {
			if (sessionOperations.get(sessionId) === settled) sessionOperations.delete(sessionId);
		});
		return result;
	};
	commandBridge = new CommandBridge({
		imageAttachmentLimits: ctx.attachments.imageLimits,
		listWorkspaces: async () => Promise.all(ctx.workspaceRegistry.list().map(async (workspace) => ({
			id: String(workspace.id),
			title: workspace.title,
			path: workspace.path,
			status: await workspace.status(),
			sessionIds: workspace.sessionIds.map(String)
		}))),
		listTasks: async () => {
			if (refreshTaskSnapshot !== void 0) return refreshTaskSnapshot();
			return taskSnapshot;
		},
		createSession: (request) => serializeSession(request.sessionId, async () => {
			const workspace = ctx.workspaceRegistry.get(request.workspaceId);
			if (workspace === void 0) throw new Error(`workspace "${request.workspaceId}" not found`);
			const result = await ctx.sessionController.create({
				workspaceId: workspace.id,
				sessionId: request.sessionId
			});
			stateFor(String(result.sessionId), String(workspace.id)).workspaceId = String(workspace.id);
			return { sessionId: String(result.sessionId) };
		}),
		prompt: (request) => serializeSession(request.sessionId, async () => {
			const workspace = ctx.workspaceRegistry.get(request.workspaceId);
			if (workspace === void 0) throw new Error(`workspace "${request.workspaceId}" not found`);
			if (!workspace.sessionIds.some((candidate) => String(candidate) === request.sessionId)) throw new Error(`session "${request.sessionId}" is not attached to workspace "${request.workspaceId}"`);
			const content = [...request.text.trim() === "" ? [] : [{
				type: "text",
				text: request.text
			}], ...request.images.map((image) => ({
				type: "image",
				...image
			}))];
			await ctx.sessionController.prompt({
				requestId: request.requestId,
				sessionId: request.sessionId,
				mode: "queue",
				content
			}, AbortSignal.timeout(3e4));
			return {
				accepted: true,
				sessionId: request.sessionId
			};
		}),
		snapshotFor: snapshotForSession
	}, instance.commandSocketPath, instance);
	refreshTaskSnapshot = async () => {
		const listed = await ctx.sessionController.list({}, AbortSignal.timeout(15e3));
		taskSnapshot = tasksFromSummaries(listed.items);
		commandBridge?.publishTasks(taskSnapshot);
		return taskSnapshot;
	};
	ctx.effect(() => {
		statusReady = false;
		commandReady = false;
		localBridge.start(() => {
			statusReady = true;
			publishInstanceManifest();
		});
		commandBridge?.start(() => {
			commandReady = true;
			publishInstanceManifest();
		});
		refreshTaskSnapshot?.().catch((error) => {
			console.warn(`[dsh-pet] initial task list unavailable: ${String(error)}`);
		});
		return () => {
			if (taskRefreshTimer !== void 0) clearTimeout(taskRefreshTimer);
			taskRefreshTimer = void 0;
			commandBridge?.stop();
			localBridge.stop();
			if (originRetryTimer !== void 0) clearTimeout(originRetryTimer);
			originRetryTimer = void 0;
			instanceManifest.remove();
			instanceManifestPublished = false;
			statusReady = false;
			commandReady = false;
		};
	}, "dsh-pet: local bridges");
	const statusRoute = {
		kind: "exact",
		path: "/api/dsh-pet/status",
		handler: (req, res) => {
			if (req.method !== "GET") {
				json(res, 405, {
					ok: false,
					error: "method-not-allowed"
				});
				return;
			}
			json(res, 200, {
				ok: true,
				enabled: true,
				...snapshot()
			});
		}
	};
	const legacyStatusRoute = {
		...statusRoute,
		path: "/api/moodball/status"
	};
	ctx.effect(() => {
		const dispose = ctx.webServer.register(statusRoute);
		const disposeLegacy = ctx.webServer.register(legacyStatusRoute);
		return () => {
			disposeLegacy();
			dispose();
		};
	}, "dsh-pet: status routes");
}
//#endregion
export { CommandBridge, HarnessInstanceManifest, LocalStateBridge, apply, createHarnessInstanceDescriptor, inject, instanceDiscoveryDirectory, instanceManifestPath, name, refreshHarnessInstanceWebURL };
