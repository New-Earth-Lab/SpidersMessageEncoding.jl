module SpidersMessageSender
using ArgParse
using FITSIO
using SpidersMessageEncoding
using Aeron
using StaticStrings

export sendevents, sendarray, AeronConfig, AeronContext


function main(ARGS)
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--dir"
        help = "path to aeron media driver shared memory file"
        arg_type = String
        required = false
        "--uri"
        help = "aeron url to publish to"
        arg_type = String
        default = "aeron:ipc"
        "--stream"
        help = "aeron stream number to publish to"
        arg_type = Int
        required = true
        "--event"
        nargs = '+'
        action = "append_arg"
        help = "one or more SPIDERS command message entry to send (--event key [=value Float | String | fits file path])"
        arg_type = String
        "--array"
        nargs = '+'
        help = "one or more SPIDERS ArrayMessage entry to send (path to a FITS file)"
        arg_type = String
        action = "append_arg"
    end
    parsed_args = parse_args(ARGS, s)
    if isnothing(parsed_args)
        return 1
    end

    dir = parsed_args["dir"]
    uri = parsed_args["uri"]
    stream = parsed_args["stream"]

    ctx = AeronContext(; dir)
    conf = AeronConfig(; uri, stream)

    errorcode = 0
    event_flags = parsed_args["event"]
    array_flags = parsed_args["array"]
    if !isempty(event_flags)
        kwargs_nest = map(event_flags) do event_entries
            return map(event_entries) do argstr
                strs =  split(argstr, "=")
                if length(strs) == 2
                    key, value = strs
                    return Symbol(key) => value
                elseif length(strs) == 1
                    key = strs[1]
                    return Symbol(key) => nothing
                else
                    error("multiple = encountered in single argument")
                end
            end
        end
        kwargs = Iterators.flatten(kwargs_nest)
        # Send command messages
        sendevents(ctx, conf; NamedTuple(kwargs)...)
    end
    bufs = []
    for array_flag in array_flags
        for array_fname in array_flag
            data = FITS(array_fname, "r") do hdus
                read(hdus[1])
            end
            sendarray(ctx, conf, data; description="")
        end
    end
    if isempty(array_flags) && isempty(event_flags)
        println(stderr, "no action provided")
        errorcode = 127
    end
    return errorcode
end


function julia_main()::Cint
    return main(ARGS)::Cint
end


"""
    sendevents([Aeron.Context]; uri, stream, key_1=value_1, key_2=value_2...)
    sendevents([Aeron.Context], conf::Aeron.Config; key_1=value_1, key_2=value_2...)

Convenience function to send a series of EventMessage in a single message
to a provided aeron stream.

You can pass an `Aeron.Context` if you have already created one, or else a new context
will be opened internally. 
You can pass an `Aeron.Config` object if you have it, otherwise you can pass the 
`uri` and `stream` parameters.

Example:
```julia
sendevents(uri="aeron:ipc", stream=1001, event=:Start)
```
"""
sendevents(;uri, stream, kwargs...) = sendevents(AeronConfig(;uri,stream); kwargs...)
sendevents(ctx::AeronContext; uri, stream, kwargs...) = sendevents(ctx, AeronConfig(;uri,stream); kwargs...)
function sendevents(conf::AeronConfig; kwargs...)
    AeronContext() do ctx
        sendevents(ctx, conf; kwargs...)
    end
end
function sendevents(ctx::AeronContext, conf::AeronConfig; kwargs...)
    Aeron.publisher(ctx, conf) do pub
        sendevents(pub; kwargs...)
    end
end
function sendevents(pub::Aeron.AeronPublication; kwargs...)
    errorcode=0

    # All messages are sent with the same correlation number as a single Aeron message (could be multiple fragments)
    corr_num = rand(Int64)

    # Prepare all messages first, and then send one after another without pause
    # Note: nested map because users can do --event abc=10 def=10 or --event abc=10 --event def=10
    messages = map(collect(kwargs)) do (key, value)
        buf = zeros(UInt8, 100000)
        event = EventMessage(buf)
        # Handle an array valued argument or a path to a FITS file
        if (value isa AbstractString && isfile(String(value))) || 
           (value isa AbstractArray)
            if value isa AbstractString
                data = FITS(value, "r") do hdus
                    read(hdus[1])
                end
            else
                data = value
            end
            buf_inner = zeros(UInt8, 512 + sizeof(data))
            size(buf_inner)
            msg = TensorMessage(buf_inner)
            # FITS files are always at least 2d. If we get a single column, treat this as a vector.
            if value isa String && ndims(data) == 2 && size(data, 2) == 1
                data = dropdims(data, dims=2)
                @info "dropping trailing dimension of size 1"
            end
            arraydata!(msg, data)
            event.header.TimestampNs           = 0 # TODO
            event.header.correlationId         = corr_num
            event.header.description           = "" # TODO. Need to be able to specify?
            resize!(buf_inner, sizeof(msg))
            if length(buf) < length(buf_inner) + sizeof(event) 
                resize!(buf, length(buf_inner) + sizeof(event))
            end
            value = msg
        elseif value isa AbstractString 
            flt = tryparse(Float64, value)
            if isnothing(flt)
                value = value
            else
                value = flt
            end
        elseif value isa Symbol
            value = String(value)
        end
        event.name = String(key)
        event.header.TimestampNs           = 0 # TODO
        event.header.correlationId         = corr_num
        event.header.description           = "command"
        setargument!(event, value)
        resize!(buf, sizeof(event))
        return buf
    end

    all_messages_concat = reduce(vcat, messages)
    status = put!(pub, all_messages_concat)
    if status != :success
        @warn "message not published" status
        errorcode += 1
    end
    return errorcode
end


sendarray(data; uri, stream, description="") = sendarray(AeronConfig(;uri,stream), data; description)
sendarray(ctx::AeronContext, data; uri, stream, description="") = sendarray(ctx, AeronConfig(;uri,stream), data; description)
function sendarray(conf::AeronConfig, data; description="")
    AeronContext() do ctx
        sendarray(ctx, conf, data; description)
    end
end
function sendarray(ctx::AeronContext, conf::AeronConfig, data;description="")
    Aeron.publisher(ctx, conf) do pub
        sendarray(pub, data; description)
    end
end

function sendarray(pub::Aeron.AeronPublication, data; description="")

    buf = zeros(UInt8, 512 + sizeof(data))
    msg = TensorMessage(buf)
    # FITS files are always at least 2d. If we get a single column, treat this as a vector.
    if ndims(data) == 2 && size(data, 2) == 1
        data = dropdims(data, dims=2)
        @info "dropping trailing dimension of size 1"
    end
    arraydata!(msg, data)
    # TODO:
    msg.header.description = description
    # cmd.timestamp = 
    # cmd.format = 
    # format = 0 implies there is another payload
    # cmd.argument = 
    # cmd.payload
    # display(cmd)
    resize!(buf, sizeof(msg))

    status = put!(pub, buf)
    if status != :success
        @warn "Message not published. Stopping." status
        return 1
    end
    return 0
end

end

#=
Example receiver:

 Aeron.subscriber(ctx, conf) do sub
        for frame in sub
            msg = SpidersMessageEncoding.sbedecode(frame.buffer)
        end
    end
=#