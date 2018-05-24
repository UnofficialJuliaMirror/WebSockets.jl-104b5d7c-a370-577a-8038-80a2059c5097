#=

A chat application using both HttpServer and HTTP to do
the same thing: Start a new task for each browser (tab) that connects.

To use:
    - include("chat_explore.jl") in REPL
    - start a browser on address 127.0.0.1:8000, and another on 127.0.0.1:8080
    - inspect global variables starting with 'last' while the chat is running asyncronously

To call in from other devices, figure out your IP address on the network and change the 'gatekeeper' code.

Note that type of 'lastreq' changes depending on whether the last call was made through HttpServer or HTTP.

Functions used as arguments are explicitly defined with names instead of anonymous functions (do..end constructs).
This may improve debugging readability at the cost of increased verbosity.

=#
global lastreq = 0
global lastws= 0
global lastmsg= 0
global lastws= 0

using HttpServer
using HTTP
using WebSockets
const CLOSEAFTER = Base.Dates.Second(1800)
const HTTPPORT = 8080
const HTTPSERVERPORT = 8000
const URL = "127.0.0.1"
const USERNAMES = Dict{String, WebSocket}()
const HTMLSTRING = readstring(Pkg.dir("WebSockets","examples","chat_explore.html"));

# If we are to access a websocket from outside
# it's websocket handler function, we need some kind of 
# mutable container for storing references: 
const WEBSOCKETS = Dict{WebSocket, Int}()

"""
Called by 'gatekeeper', this function stays active while the 
particular websocket is open. The argument is an open websocket.
Other instances of the function run in other tasks. The tasks
are generated by either HTTP or HttpServer.
"""
function usews(thisws)
    global lastws = thisws
    push!(WEBSOCKETS, thisws => length(WEBSOCKETS) +1 )
    t1 = now() + CLOSEAFTER
    username = ""
    while now() < t1
        # This next call waits for a message to
        # appear on the socket. If there is none,
        # this task yields to other tasks.
        data, success = readguarded(thisws)
        !success && break
        global lastmsg = msg = String(data)
        print("Received: $msg ")
        if username == ""
            username = approvedusername(msg, thisws)
            if username != ""
                println("from new user $username ")
                !writeguarded(thisws, username) && break 
                println("Tell everybody about $username")
                foreach(keys(WEBSOCKETS)) do ws
                    writeguarded(ws, username * " enters chat")
                end
            else
                println(", username taken!")
                !writeguarded(thisws, "Username taken!") && break
            end 
        else
            println("from $username ")
            distributemsg(msg, thisws)
            startswith(msg, "exit") && break
        end
    end
    exitmsg = username == "" ? "unknown" : username * " has left"
    distributemsg(exitmsg, thisws)
    println(exitmsg)
    # No need to close the websocket. Just clean up external references:
    removereferences(thisws)
    nothing
end

function removereferences(ws)
    haskey(WEBSOCKETS, ws) && pop!(WEBSOCKETS, ws)
    for (discardname, wsref) in USERNAMES
        if wsref === ws
            pop!(USERNAMES, discardname)
            break
        end
    end
    nothing
end


function approvedusername(msg, ws)
    !startswith(msg, "userName:") && return ""
    newname = msg[length("userName:") + 1:end]
    newname =="" && return ""
    haskey(USERNAMES, newname) && return ""
    push!(USERNAMES, newname => ws)
    newname
end


function distributemsg(msgout, not_to_ws)
    foreach(keys(WEBSOCKETS)) do ws
        if ws !== not_to_ws
            writeguarded(ws, msgout)
        end
    end
    nothing
end


"""
`Server => gatekeeper(Request, WebSocket) => usews(WebSocket)`

The gatekeeper makes it a little harder to connect with
malicious code. It inspects the request that was upgraded
to a a websocket.
"""
function gatekeeper(req, ws)
    global lastreq = req
    global lastws = ws
    orig = WebSockets.origin(req)
    if startswith(orig, "http://localhost") || startswith(orig, "http://127.0.0.1")
        usews(ws)
    else
        warn("Unauthorized websocket connection, $orig not approved by gatekeeper")
    end
    nothing
end

"Request to response. Response is the predefined HTML page with some javascript"
req2resp(req::HttpServer.Request, resp) = HTMLSTRING |> Response
req2resp(req::HTTP.Request) =       HTMLSTRING |> HTTP.Response

# Both server definitions need two function wrappers; one handler function for page requests,
# one for opening websockets (which the javascript in the HTML page will try to do)
server_httpserver = Server(HttpHandler(req2resp), WebSocketHandler(gatekeeper))
server_HTTP = WebSockets.ServerWS(HTTP.HandlerFunction(req2resp), WebSockets.WebsocketHandler(gatekeeper))

# Start the HTTP server asyncronously, and stop it later
litas_HTTP = @schedule WebSockets.serve(server_HTTP, URL, HTTPPORT, false)
@schedule begin
    println("HTTP server listening on $URL:$HTTPPORT for $CLOSEAFTER")
    sleep(CLOSEAFTER.value)
    println("Time out, closing down $HTTPPORT")
    Base.throwto(litas_HTTP, InterruptException())
end

# Start the HttpServer asyncronously, stop it later
litas_httpserver = @schedule run(server_httpserver, HTTPSERVERPORT)
@schedule begin
          println("HttpServer listening on $URL:$HTTPSERVERPORT for $CLOSEAFTER")
          sleep(CLOSEAFTER.value + 2)
          println("Time out, closing down $HTTPSERVERPORT")
          Base.throwto(litas_httpserver, InterruptException())
end

# Note that stopping the HttpServer in a while will send an error messages to the 
# console. We could get rid of the messages by binding the task to a Channel. 
# However, we can't get rid of ECONNRESET messages in that way. This is 
# because the errors are triggered in tasks generated by litas_httpserver again,
# and those aren't channeled anywhere.

nothing