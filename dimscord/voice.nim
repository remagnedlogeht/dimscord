## Currently handling the discord voice gateway (WIP)
## Playing audio will be added later.
import asyncdispatch, ws, asyncnet
import objects, json, times, constants
import strutils, nativesockets

const
    opIdentify = 0
    opSelectProtocol = 1
    opReady = 2
    opHeartbeat = 3
    opSessionDescription = 4
    opSpeaking = 5
    opHeartbeatAck = 6
    opResume = 7
    opHello = 8
    opResumed = 9
    opClientDisconnect = 13

var
    ip: string
    port: int
    reconnectable = true
    discovering = false

# proc writeBigUint16(strm: StringStream, num: uint16) = 
#     var
#         tmp: uint16
#         num = num
#     bigEndian16(addr tmp, addr num)
#     strm.write(tmp)

# proc writeBigUint32(strm: StringStream, num: uint32) = 
#     var
#         tmp: uint32
#         num = num
#     bigEndian32(addr tmp, addr num)
#     strm.write(tmp)

# proc writeString(strm: StringStream, num: string) =
#     var
#         tmp: string
#         num = num
#     strm.write(num)

proc reset(v: VoiceClient) {.used.} =
    v.resuming = false

    v.hbAck = false
    v.hbSent = false
    v.ready = false

    ip = ""
    port = -1

    v.heartbeating = false
    v.retry_info = (ms: 1000, attempts: 0)
    v.lastHBTransmit = 0
    v.lastHBReceived = 0

proc extractCloseData(data: string): tuple[code: int, reason: string] = # Code from: https://github.com/niv/websocket.nim/blame/master/websocket/shared.nim#L230
    var data = data
    result.code =
        if data.len >= 2:
            cast[ptr uint16](addr data[0])[].htons.int
        else:
            0
    result.reason = if data.len > 2: data[2..^1] else: ""

proc handleDisconnect(v: VoiceClient, msg: string): bool {.used.} =
    let closeData = extractCloseData(msg)

    log("Socket suspended", (
        code: closeData.code,
        reason: closeData.reason
    ))
    v.stop = true
    v.reset()

    result = true

    if closeData.code in [4004, 4006, 4012, 4014]:
        result = false
        log("Fatal error: " & closeData.reason)

proc sendSock(v: VoiceClient, opcode: int, data: JsonNode) {.async.} =
    log "Sending OP: " & $opcode

    await v.connection.send($(%*{
        "op": opcode,
        "d": data
    }))

proc sockClosed(v: VoiceClient): bool {.used.} =
    return v.connection == nil or v.connection.tcpSocket.isClosed or v.stop

proc resume(v: VoiceClient) {.async.} =
    if v.resuming or v.sockClosed: return

    # v.resuming = true

    log "Attempting to resume\n" &
        "  server_id: " & v.guild_id & "\n" &
        "  session_id: " & v.session_id

    await v.sendSock(opResume, %*{
        "server_id": v.guild_id,
        "session_id": v.session_id,
        "token": v.token
    })

proc identify(v: VoiceClient) {.async.} =
    if v.sockClosed and not v.resuming: return

    log "Sending identify."

    await v.sendSock(opIdentify, %*{
        "server_id": v.guild_id,
        "user_id": v.shard.user.id,
        "session_id": v.session_id,
        "token": v.token
    })

proc selectProtocol(v: VoiceClient) {.async.} =
    if v.sockClosed: return

    await v.sendSock(opSelectProtocol, %*{
        "protocol": "udp",
        "data": {
            "address": ip,
            "port": port,
            "mode": "xsalsa20_poly1305_suffix"
        }
    })

proc reconnect(v: VoiceClient) {.async.} =
    if (v.reconnecting or not v.stop) and not reconnectable: return
    v.reconnecting = true
    v.retry_info.attempts += 1

    var url = v.endpoint

    if v.retry_info.attempts > 3:
        if not v.networkError:
            v.networkError = true
            log "A network error has been detected."

    let prefix = if url.startsWith("gateway"): "ws://" & url else: url

    log "Connecting to " & $prefix

    try:
        let future = newWebSocket(prefix)

        v.reconnecting = false
        v.stop = false

        if (await withTimeout(future, 25000)) == false:
            log "Websocket timed out.\n\n  Retrying connection..."

            await v.reconnect()
            return

        v.connection = await future
        v.hbAck = true

        v.retry_info.attempts = 0
        v.retry_info.ms = max(v.retry_info.ms - 5000, 1000)

        if v.networkError:
            log "Connection established after network error."
            v.retry_info = (ms: 1000, attempts: 0)
            v.networkError = false
    except:
        log "Error occurred: \n" & getCurrentExceptionMsg()

        log("Failed to connect, reconnecting in " & $v.retry_info.ms & "ms", (
            attempt: v.retry_info.attempts
        ))
        v.reconnecting = false
        await sleepAsync v.retry_info.ms
        await v.reconnect()
        return


proc disconnect*(v: VoiceClient) {.async.} =
    ## Disconnects a voice client.
    if v.sockClosed: return

    log "Voice Client disconnecting..."

    v.stop = true
    v.reset()

    if v.connection != nil:
        v.connection.close()


    log "Shard reconnecting after disconnect..."
    await v.reconnect()

proc heartbeat(v: VoiceClient) {.async.} =
    if v.sockClosed: return

    # if not v.hbAck and v.session_id != "":
    #     log "A zombied connection has been detected"
    #     await v.disconnect()
    #     return

    log "Sending heartbeat."
    v.hbAck = false

    await v.sendSock(opHeartbeat,
        newJInt getTime().toUnix().BiggestInt * 1000
    )
    v.lastHBTransmit = getTime().toUnixFloat()
    v.hbSent = true

proc setupHeartbeatInterval(v: VoiceClient) {.async.} =
    if not v.heartbeating: return
    v.heartbeating = true

    while not v.sockClosed:
        let hbTime = int((getTime().toUnixFloat() - v.lastHBTransmit) * 1000)

        if hbTime < v.interval - 8000 and v.lastHBTransmit != 0.0:
            break

        await v.heartbeat()
        await sleepAsync v.interval

proc handleSocketMessage(v: VoiceClient) {.async.} =
    var packet: (Opcode, string)

    var shouldReconnect = true
    while not v.sockClosed:
        try:
            packet = await v.connection.receivePacket()
        except:
            let exceptn = getCurrentExceptionMsg()
            log "Error occurred in websocket ::\n" & getCurrentExceptionMsg()

            v.stop = true
            v.heartbeating = false

            if exceptn.startsWith("The semaphore timeout period has expired."):
                log "A network error has been detected."

                v.networkError = true
                break
            else:
                break

        var data: JsonNode

        try:
            data = parseJson(packet[1])
        except:
            log "An error occurred while parsing data: " & packet[1]
            await v.disconnect()
            await v.voice_events.on_disconnect(v)
            break

        if data["op"].num == opHello:
            log "Received 'HELLO' from the voice gateway."
            v.interval = int data["d"]["heartbeat_interval"].getFloat

            await v.identify()

            if not v.heartbeating:
                v.heartbeating = true
                asyncCheck v.setupHeartbeatInterval()
        elif data["op"].num == opHeartbeatAck:
            v.lastHBReceived = getTime().toUnixFloat()
            v.hbSent = false
            log "Heartbeat Acknowledged by Discord."

            v.hbAck = true
        elif data["op"].num == opReady:
            ip = data["d"]["ip"].str
            port = data["d"]["port"].getInt
            v.ready = true
            await v.voice_events.on_ready(v)
        elif data["op"].num == opResumed:
            v.resuming = false
        else:
            discard

    if not reconnectable: return

    if packet[0] == Close:
        shouldReconnect = v.handleDisconnect(packet[1])
    v.stop = true
    v.reset()

    if shouldReconnect:
        await v.reconnect()
        await sleepAsync 2000

        if not v.networkError: await v.handleSocketMessage()
    else:
        return

proc startSession*(v: VoiceClient) {.async.} =
    ## Start a discord voice session.
    log "Connecting to voice gateway"

    try:
        v.endpoint = v.endpoint.replace(":443", "")
        let future = newWebSocket(v.endpoint)

        if (await withTimeout(future, 25000)) == false:
            log "Websocket timed out.\n\n  Retrying connection..."
            await v.startSession()
            return
        v.connection = await future
        v.hbAck = true

        log "Socket opened."
    except:
        v.stop = true
        raise newException(Exception, getCurrentExceptionMsg())
    try:
        await v.handleSocketMessage()
    except:
        if not getCurrentExceptionMsg()[0].isAlphaNumeric: return
        raise newException(Exception, getCurrentExceptionMsg())

# proc playFile*(v: VoiceClient) {.async.} =
#     ## Play an audio file.
#     discard

# proc openYTDLStream*(v: VoiceClient)

# proc play*(v: VoiceClient) {.async.} =
#     ## Play with 
#     discard

# proc latency*(v: VoiceClient) {.async.} =
#     ## Get latency of the voice client.
#     discard