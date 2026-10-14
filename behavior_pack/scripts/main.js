/**
 * @fileoverview Native Bedrock Custom Commands using proper status returns and namespaces.
 */
import { system, world, CommandPermissionLevel, CustomCommandStatus, CustomCommandParamType } from "@minecraft/server";
import { http, HttpRequest, HttpRequestMethod, HttpHeader } from "@minecraft/server-net";

system.beforeEvents.startup.subscribe((init) => {
    /** @type {import("@minecraft/server").CustomCommand} */
    const deferCommand = {
        name: "manager:defer",
        description: "Postpones the upcoming server restart.",
        permissionLevel: 1,
        cheatsRequired: false
    };

    /** @type {import("@minecraft/server").CustomCommand} */
    const restartCommand = {
        name: "manager:restart",
        description: "Initiates a scheduled server restart.",
        permissionLevel: 1,
        cheatsRequired: false,
        optionalParameters: [
            { type: CustomCommandParamType.Integer, name: "minutes" }
        ]
    };

    init.customCommandRegistry.registerCommand(deferCommand, (origin) => {
        // Fire async request, handle in-game response safely via system.run
        const executeDeferral = async () => {
            const request = new HttpRequest("http://127.0.0.1:3456/defer");
            request.method = HttpRequestMethod.Post;

            try {
                const response = await http.request(request);
                system.run(() => {
                    if (response.status === 200) {
                        world.sendMessage("§e[Server] §aThe upcoming scheduled server restart has been postponed.");
                    } else {
                        world.sendMessage(`§c[Manager] Webhook returned HTTP ${response.status}`);
                    }
                });
            } catch (error) {
                system.run(() => {
                    world.sendMessage("§c[Manager] Network error: Failed to reach local manager API endpoint.");
                });
            }
        };

        executeDeferral();

        return {
            message: "Deferral command dispatched.",
            status: CustomCommandStatus.Success
        };
    });

    init.customCommandRegistry.registerCommand(restartCommand, (origin, minutes) => {
        const executeRestart = async () => {
            const request = new HttpRequest("http://127.0.0.1:3456/restart");
            request.method = HttpRequestMethod.Post;

            if (minutes !== undefined) {
                request.body = JSON.stringify({ minutes: minutes });
                request.headers = [new HttpHeader("Content-Type", "application/json")];
            }

            try {
                const response = await http.request(request);
                system.run(() => {
                    if (response.status === 200) {
                        const minsText = minutes !== undefined ? `${minutes} minutes` : "30 minutes";
                        world.sendMessage(`§e[Server] §cServer restart initiated. Rebooting in ${minsText}.`);
                    } else {
                        world.sendMessage(`§c[Manager] Webhook returned HTTP ${response.status}`);
                    }
                });
            } catch (error) {
                system.run(() => {
                    world.sendMessage("§c[Manager] Network error: Failed to reach local manager API endpoint.");
                });
            }
        };

        executeRestart();

        const minsText = minutes !== undefined ? `${minutes}m` : "default";
        return {
            message: `Restart command dispatched (${minsText}).`,
            status: CustomCommandStatus.Success
        };
    });
});

