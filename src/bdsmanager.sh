#!/usr/bin/env bash
#
# MooVoidSMP Bedrock Dedicated Server manager
#
#
#   bds-manager.sh                  Run the manager (systemd entry point)
#   bds-manager.sh console          Attach to the live server console
#   bds-manager.sh cmd <cmd>        Send a single command to the server
#   bds-manager.sh restart          Warn players (30m/5m/1m), then backup + restart
#   bds-manager.sh restart <mins>   Warn players, custom countdown in minutes, backup + restart
#   bds-manager.sh restart now      Backup + restart immediately, no warnings
#   bds-manager.sh defer            Defer or cancel an upcoming scheduled restart
#
# Scheduled restarts are triggered externally (systemd timer or cron) via `restart`.
# The manager itself only handles crash recovery and executes restart requests.
#
#   ver. 1.0.4 | 10/14/2026 | DJ Stomp
#    - Added defer capability
#    - Added support for custom restart durations
#    - Upgraded interoperability with systemd timers
#

readonly SERVER="/home/moo/MooVoidSMP/SMP"
readonly BACKUPS="$SERVER/backups"
readonly BDS_EXEC="./bedrock_server"
readonly FIFO="$SERVER/.bds-console"
readonly LOG="$SERVER/logs/manager-console.log"
readonly LOCK="$SERVER/.manager.lock"
readonly RESTART_REQUEST="$SERVER/.restart-request"
readonly SKIP_FILE="$SERVER/.skip"

readonly SIDECAR_SERVICES=(thirdeye mcxboxbroadcast)
readonly CRASH_RESTART_DELAY=10
readonly STARTUP_GRACE=8
readonly POST_START_DELAY=15
readonly STOP_TIMEOUT=90
readonly KEEP_BACKUPS=0

readonly WARN_AT=(1800 300 60)
readonly WARN_MESSAGES=(
    "say §eServer restart in 30 minutes! Please finish what you are doing."
    "say §eServer restart in 5 minutes! Please get somewhere safe."
    "say §cServer restart in 1 MINUTE! Save your items!"
)

BDS_PID=""
SHUTTING_DOWN=0

#######################################
# Prints a formatted log entry to stdout.
# Arguments:
#   Log message string.
# Outputs:
#   Prefixed log entry to stdout.
#######################################
log() {
    echo "[Manager] $*"
}

#######################################
# Prints an eye-catching banner block.
# Arguments:
#   Banner message string.
# Outputs:
#   Enclosed banner text to stdout.
#######################################
banner() {
    echo
    echo "=============================================="
    echo "$*"
    echo "=============================================="
}

#######################################
# Verifies that the named FIFO pipe exists.
# Globals:
#   FIFO
# Returns:
#   0 if pipe exists, exits 1 otherwise.
#######################################
require_pipe() {
    [ -p "$FIFO" ] && return 0
    echo "[Console] Manager is not running"
    exit 1
}

#######################################
# Sends a raw command line into the server pipe.
# Globals:
#   FIFO
#   LOG
# Arguments:
#   Command strings to evaluate.
# Outputs:
#   Last 5 log entries from manager log.
#######################################
cmd_send() {
    require_pipe
    printf '%s\n' "$*" > "$FIFO"
    echo "[Console] Sent: $*"
    sleep 1
    tail -n 5 "$LOG" 2>/dev/null
}

#######################################
# Attaches an interactive terminal to the server console.
# Globals:
#   FIFO
#   LOG
#######################################
cmd_console() {
    require_pipe
    banner " MooVoidSMP Live Console"

    tail -n 30 -f "$LOG" &
    local tail_pid=$!
    trap 'kill "$tail_pid" 2>/dev/null' EXIT
    trap 'echo; echo "[Console] Detached."; exit 0' INT TERM

    local line
    while IFS= read -r -e line; do
        case "$line" in
            "") continue ;;
            exit|quit|detach) break ;;
            stop)
                echo "[Console] Use: sudo systemctl stop moovoidsmp"
                continue
                ;;
        esac
        history -s "$line"
        [ -p "$FIFO" ] || break
        printf '%s\n' "$line" > "$FIFO"
    done
    echo "[Console] Detached."
}

#######################################
# Queues a restart request file for the manager loop.
# Globals:
#   RESTART_REQUEST
# Arguments:
#   arg - Optional. 'now' for immediate, or an integer (1-59) for minutes.
#######################################
cmd_restart() {
    local arg="${1:-}"
    local mode="countdown"
    local mins=""

    case "$arg" in
        now)
            mode="now"
            ;;
        "")
            ;;
        *)
            if [[ "$arg" =~ ^[0-9]+$ ]] && [ "$arg" -gt 0 ] && [ "$arg" -lt 60 ]; then
                mins="$arg"
            else
                echo "[Manager] Invalid argument. Use 'now' or a number of minutes (1-59)." >&2
                usage
                exit 1
            fi
            ;;
    esac

    require_pipe
    
    if [ -n "$mins" ]; then
        printf '%s %s\n' "$mode" "$mins" > "$RESTART_REQUEST"
        echo "[Console] Restart requested (countdown, ${mins}m)"
    else
        printf '%s\n' "$mode" > "$RESTART_REQUEST"
        echo "[Console] Restart requested ($mode)"
    fi
}

#######################################
# Creates the defer lockout file to cancel upcoming restarts.
# Globals:
#   SKIP_FILE
#######################################
cmd_defer() {
    touch "$SKIP_FILE"
    echo "[Console] Defer request registered ($SKIP_FILE created)"
}

#######################################
# Prints CLI usage instructions.
#######################################
usage() {
    echo "Usage:"
    echo "  $0              Run the server manager"
    echo "  $0 console      Attach to the live server console"
    echo "  $0 cmd <cmd>    Send a single command"
    echo "  $0 restart [now | mins] Warn players, backup, and restart"
    echo "  $0 defer        Defer or cancel an upcoming restart"
}

#######################################
# Checks whether the BDS PID is active.
# Globals:
#   BDS_PID
# Returns:
#   0 if running, 1 otherwise.
#######################################
server_running() {
    [ -n "$BDS_PID" ] && kill -0 "$BDS_PID" 2>/dev/null
}

#######################################
# Writes a command directly into the BDS process file descriptor.
# Arguments:
#   cmd - Server command string.
# Returns:
#   0 on write, 1 if server inactive.
#######################################
send_cmd() {
    server_running || return 1
    printf '%s\n' "$1" >&3
}

#######################################
# Reaps the BDS process and resets state tracking.
# Globals:
#   BDS_PID
#######################################
reap_server() {
    [ -n "$BDS_PID" ] && wait "$BDS_PID" 2>/dev/null
    BDS_PID=""
}

#######################################
# Starts the Bedrock Dedicated Server child process.
# Globals:
#   SERVER
#   BDS_EXEC
#   FIFO
#   LOG
#   BDS_PID
#   STARTUP_GRACE
# Returns:
#   0 on verified startup, 1 on failure.
#######################################
start_server() {
    if server_running; then
        log "BDS already running."
        return 0
    fi

    banner "[Manager] Starting MooVoidSMP BDS..."

    cd "$SERVER" || return 1
    LD_LIBRARY_PATH=. "$BDS_EXEC" < "$FIFO" >> "$LOG" 2>&1 9>&- &
    BDS_PID=$!
    log "BDS PID: $BDS_PID"
    sleep "$STARTUP_GRACE"

    if server_running; then
        log "BDS started successfully."
        return 0
    fi

    log "BDS failed to start!"
    reap_server
    tail -n 60 "$LOG" 2>/dev/null
    return 1
}

#######################################
# Continuously attempts to bring BDS online until running or shutdown.
# Globals:
#   SHUTTING_DOWN
#   CRASH_RESTART_DELAY
# Returns:
#   0 on success, 1 if manager is shutting down.
#######################################
start_server_loop() {
    while [ "$SHUTTING_DOWN" -eq 0 ]; do
        start_server && return 0
        log "Retrying startup in ${CRASH_RESTART_DELAY} seconds..."
        sleep "$CRASH_RESTART_DELAY"
    done
    return 1
}

#######################################
# Flushes and holds the world save state via BDS commands.
#######################################
save_world() {
    log "Requesting world save..."
    send_cmd "save hold"
    sleep 5
    send_cmd "save query"
    sleep 5
    send_cmd "save resume"
    sleep 2
}

#######################################
# Polls until the BDS child process exits or timeout expires.
# Globals:
#   STOP_TIMEOUT
#######################################
wait_for_exit() {
    local waited=0
    while server_running && [ "$waited" -lt "$STOP_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
}

#######################################
# Stops BDS gracefully with progressive escalation to SIGTERM and SIGKILL.
# Globals:
#   BDS_PID
# Arguments:
#   reason - Context string ("shutdown" or "restart").
#######################################
stop_server() {
    local reason="${1:-restart}"

    if ! server_running; then
        log "BDS already stopped."
        return 0
    fi

    banner "[Manager] Stopping MooVoidSMP BDS"

    if [ "$reason" = "shutdown" ]; then
        send_cmd "say §cMooVoidSMP is shutting down!"
    else
        send_cmd "say §cServer restarting now!"
    fi
    sleep 3

    save_world
    log "Sending stop command..."
    send_cmd "stop"
    wait_for_exit

    if server_running; then
        log "BDS did not stop normally. Sending SIGTERM..."
        kill -TERM "$BDS_PID" 2>/dev/null
        sleep 10
    fi
    if server_running; then
        log "Force killing BDS..."
        kill -KILL "$BDS_PID" 2>/dev/null
    fi

    reap_server
    log "BDS stopped."
}

#######################################
# Deletes older archive files exceeding KEEP_BACKUPS threshold.
# Globals:
#   BACKUPS
#   KEEP_BACKUPS
#######################################
prune_backups() {
    [ "$KEEP_BACKUPS" -gt 0 ] || return 0
    ls -1t "$BACKUPS"/MooVoidSMP-*.zip 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f --
}

#######################################
# Packages the server directory into a dated zip archive.
# Globals:
#   SERVER
#   BACKUPS
# Returns:
#   0 on archive success, 1 on failure.
#######################################
backup_server() {
    local stamp backup_file
    stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    backup_file="$BACKUPS/MooVoidSMP-$stamp.zip"

    banner "[Manager] Creating BDS backup
[Manager] $backup_file"

    if ! command -v zip >/dev/null 2>&1; then
        log "WARNING: zip not installed"
        return 1
    fi

    cd "$SERVER" || return 1
    if zip -r -9 -q -y "$backup_file" . -x "backups/*" "./backups/*" "logs/*" "./logs/*" "crash-reports/*" "./crash-reports/*" ".bds-console" "./.bds-console" ".manager.lock" "./.manager.lock" ".restart-request" "./.restart-request" ".skip" "./.skip"; then
        log "Backup completed successfully ($(du -h "$backup_file" | cut -f1))."
        prune_backups
        return 0
    fi

    log "WARNING: Backup failed!"
    rm -f "$backup_file"
    return 1
}

#######################################
# Restarts a specific systemd service unit.
# Arguments:
#   service - Name of the systemd unit.
#######################################
restart_service() {
    local service="$1"
    log "Restarting $service..."
    if sudo systemctl restart "$service" 2>/dev/null; then
        log "$service restarted successfully."
    else
        log "WARNING: Failed to restart $service."
    fi
}

#######################################
# Iterates through configured sidecar services and triggers restarts.
# Globals:
#   SIDECAR_SERVICES
#######################################
restart_sidecars() {
    local service
    for service in "${SIDECAR_SERVICES[@]}"; do
        restart_service "$service"
    done
}

#######################################
# Brings BDS online and restarts sidecar services once verified.
# Globals:
#   SHUTTING_DOWN
#   POST_START_DELAY
# Arguments:
#   announcement - In-game message to broadcast upon full launch.
#######################################
bring_online() {
    local announcement="$1"

    start_server_loop
    [ "$SHUTTING_DOWN" -eq 1 ] && return
    sleep "$POST_START_DELAY"

    if server_running; then
        send_cmd "say $announcement"
        restart_sidecars
    fi
}

#######################################
# Inspects and consumes the deferral lockout flag.
# Globals:
#   SKIP_FILE
# Returns:
#   0 if lockout flag was found and cleared, 1 otherwise.
#######################################
check_defer() {
    if [ -f "$SKIP_FILE" ]; then
        log "Defer flag found ($SKIP_FILE). Aborting restart operation."
        rm -f "$SKIP_FILE"
        return 0
    fi
    return 1
}

#######################################
# Tracks restart warning stages and monitors for deferral signals.
# Globals:
#   SHUTTING_DOWN
#   WARN_AT
#   WARN_MESSAGES
# Arguments:
#   duration_sec - Length of the restart countdown in seconds.
# Returns:
#   0 on full countdown completion, 1 if aborted, deferred, or terminated.
#######################################
countdown_restart() {
    local duration_sec="${1:-1800}"
    local deadline=$(( $(date +%s) + duration_sec ))
    local sent=(0 0 0)
    local remaining i

    for i in "${!WARN_AT[@]}"; do
        if [ "$duration_sec" -lt "${WARN_AT[$i]}" ]; then
            sent[$i]=1
        fi
    done

    log "Restart countdown started (${duration_sec}s)."
    while true; do
        { [ "$SHUTTING_DOWN" -eq 0 ] && server_running; } || return 1

        if check_defer; then
            return 1
        fi

        remaining=$(( deadline - $(date +%s) ))
        [ "$remaining" -le 0 ] && return 0

        for i in "${!WARN_AT[@]}"; do
            if [ "${sent[$i]}" -eq 0 ] && [ "$remaining" -le "${WARN_AT[$i]}" ]; then
                if check_defer; then
                    return 1
                fi
                send_cmd "${WARN_MESSAGES[$i]}"
                sent[$i]=1
                log "Restart warning sent (${WARN_AT[$i]}s)."
            fi
        done
        sleep 5
    done
}

#######################################
# Executes the full scheduled restart sequence including world backup.
# Globals:
#   SHUTTING_DOWN
#######################################
scheduled_restart() {
    banner "[Manager] SCHEDULED RESTART"

    stop_server "restart"
    log "Server offline. Starting backup..."
    backup_server
    [ "$SHUTTING_DOWN" -eq 1 ] && return

    log "Restarting BDS in 5 seconds..."
    sleep 5
    bring_online "§aMooVoidSMP is back online! Have fun!"
}

#######################################
# Recovers the server process after an unexpected crash.
# Globals:
#   SHUTTING_DOWN
#   CRASH_RESTART_DELAY
#######################################
handle_crash() {
    [ "$SHUTTING_DOWN" -eq 1 ] && return

    banner "[Manager] BDS STOPPED UNEXPECTEDLY!"
    reap_server

    log "Restarting in ${CRASH_RESTART_DELAY} seconds..."
    sleep "$CRASH_RESTART_DELAY"
    bring_online "§aServer recovered from a crash and is back online!"
}

#######################################
# Retrieves and removes pending restart requests from disk.
# Globals:
#   RESTART_REQUEST
# Outputs:
#   Contents of the request file to stdout.
# Returns:
#   0 if a request was present, 1 otherwise.
#######################################
take_restart_request() {
    [ -f "$RESTART_REQUEST" ] || return 1
    cat "$RESTART_REQUEST"
    rm -f "$RESTART_REQUEST"
}

#######################################
# Manages execution flow for restart requests with defer validation.
# Globals:
#   RESTART_REQUEST
# Arguments:
#   request - Raw string payload extracted from the restart request file.
#######################################
handle_restart_request() {
    local request="$1"
    local mode
    local mins
    
    read -r mode mins <<< "$request"
    
    log "Restart request received ($mode${mins:+ $mins m})."

    if check_defer; then
        return 0
    fi

    if [ "$mode" != "now" ]; then
        local duration_sec=1800
        if [ -n "$mins" ] && [ "$mins" -eq "$mins" ] 2>/dev/null; then
            duration_sec=$((mins * 60))
        fi
        
        if ! countdown_restart "$duration_sec"; then
            return 0
        fi
    fi

    if check_defer; then
        return 0
    fi

    scheduled_restart
}

#######################################
# Closes file descriptors and tears down named pipe.
# Globals:
#   FIFO
#######################################
cleanup_fifo() {
    exec 3>&- 2>/dev/null
    rm -f "$FIFO"
}

#######################################
# Handles clean shutdown signaled by systemd or operator.
# Globals:
#   SHUTTING_DOWN
#######################################
shutdown_manager() {
    [ "$SHUTTING_DOWN" -eq 1 ] && return
    SHUTTING_DOWN=1

    banner "[Manager] systemd requested shutdown."

    if server_running; then
        stop_server "shutdown"
        log "Creating shutdown backup..."
        backup_server
    fi

    cleanup_fifo
    log "MooVoidSMP BDS Manager stopped."
    exit 0
}

#######################################
# Validates directory structures, binaries, locks, and pipes.
# Globals:
#   BACKUPS
#   SERVER
#   LOCK
#   FIFO
#   RESTART_REQUEST
#   SKIP_FILE
#######################################
preflight() {
    mkdir -p "$BACKUPS" "$SERVER/logs"
    cd "$SERVER" || { log "ERROR: Server folder not found"; exit 1; }
    [ -f "$SERVER/bedrock_server" ] || { log "ERROR: bedrock_server not found"; exit 1; }

    exec 9>"$LOCK"
    flock -n 9 || { log "ERROR: Manager already running"; exit 1; }

    chmod +x "$SERVER/bedrock_server" 2>/dev/null
    rm -f "$FIFO" "$RESTART_REQUEST" "$SKIP_FILE"
    mkfifo "$FIFO"
    chmod 660 "$FIFO"
    exec 3<>"$FIFO"
}

#######################################
# Main manager loop coordinating state and external requests.
# Globals:
#   SERVER
#   SIDECAR_SERVICES
#   SHUTTING_DOWN
#######################################
run_manager() {
    preflight
    trap shutdown_manager SIGTERM SIGINT SIGHUP
    trap cleanup_fifo EXIT

    banner " MooVoidSMP BDS Manager
 Server Folder:     $SERVER
 Scheduled Restart: Via cron ($0 restart)
 Backup:            On every restart and shutdown
 Crash Recovery:    Enabled
 Sidecars:          Restarted with server (${SIDECAR_SERVICES[*]})
 Console:           $0 console"

    start_server_loop

    local request
    while [ "$SHUTTING_DOWN" -eq 0 ]; do
        if ! server_running; then
            handle_crash
            continue
        fi
        if request="$(take_restart_request)"; then
            handle_restart_request "$request"
        fi
        sleep 5
    done
}

case "${1:-}" in
    cmd)      shift; cmd_send "$@" ;;
    console)  cmd_console ;;
    restart)  shift; cmd_restart "$@" ;;
    defer)    cmd_defer ;;
    ""|run)   run_manager ;;
    *)        usage; exit 1 ;;
esac
