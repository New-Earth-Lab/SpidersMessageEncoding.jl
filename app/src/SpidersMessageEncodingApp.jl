module SpidersMessageEncodingApp
using ArgParse
using FITSIO
using SpidersMessageEncoding
using Aeron


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
        required = true
        "--stream"
        help = "aeron stream number to publish to"
        arg_type = Int
        required = true
        "--cmd"
        nargs = '+'
        action = "append_arg"
        help = "one or more SPIDERS command message entry to send (--command cmd [argument] [payload fits file path])"
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
    command_flags = parsed_args["cmd"]
    array_flags = parsed_args["array"]
    if !isempty(command_flags)
        # Prepare all messages first, and then send one after another without pause
        # Note: nested map because users can do --cmd abc=10 def=10 or --cmd abc=10 --cmd def=10
        messages = map(command_flags) do command_entries
            return map(command_entries) do argstr
                buf = zeros(UInt8, 100000)
                cmd = CommandMessage(buf)
                key, value = split(argstr, "=")
                if isfile(value)
                    data = FITS(value, "r") do hdus
                        read(hdus[1])
                    end
                    buf_inner = zeros(UInt8, 512 + sizeof(data))
                    size(buf_inner)
                    msg = TensorMessage(buf_inner)
                    # FITS files are always at least 2d. If we get a single column, treat this as a vector.
                    if ndims(data) == 2 && size(data, 2) == 1
                        data = dropdims(data, dims=2)
                        @info "dropping trailing dimension of size 1"
                    end
                    arraydata!(msg, data)
                    # TODO:
                    # cmd.timestamp = 
                    # cmd.format = 
                    # format = 0 implies there is another payload
                    # cmd.argument = 
                    # cmd.payload
                    # display(cmd)
                    resize!(buf_inner, sizeof(msg))
                    if length(buf) < length(buf_inner) + sizeof(cmd) 
                        resize!(buf, length(buf_inner) + sizeof(cmd))
                    end
                    value_parsed = msg
                else
                    value_parsed = eval(Meta.parse(value)) # dangerous: evaluate user code directly since we don't know what type they want.
                end
                cmd.command = key
                setargument!(cmd, value_parsed)
                resize!(buf, sizeof(cmd))
                return buf
            end
        end
        messages = collect(Iterators.flatten(messages))

        # Complete by sending a commit message after all messages
        buf = zeros(UInt8, 512)
        commit_msg = CommitMessage(buf)
        # TODO: sequence number etc
        resize!(buf, sizeof(commit_msg))
        push!(messages, buf)


        # TODO: working around a bug in Aeron.jl publisher code by connecting twice
        Aeron.publisher(ctx, conf) do pub
        end
        Aeron.publisher(ctx, conf) do pub
            for message in messages
                status = put!(pub, message)
                if status != :success
                    @warn "message not published" status
                    errorcode += 1
                end
            end
        end
    end
    bufs = []
    for array_flag in array_flags
        for array_fname in array_flag
            data = FITS(array_fname, "r") do hdus
                read(hdus[1])
            end
            buf = zeros(UInt8, 512 + sizeof(data))
            msg = TensorMessage(buf)
            # FITS files are always at least 2d. If we get a single column, treat this as a vector.
            if ndims(data) == 2 && size(data, 2) == 1
                data = dropdims(data, dims=2)
                @info "dropping trailing dimension of size 1"
            end
            arraydata!(msg, data)
            # TODO:
            # cmd.timestamp = 
            # cmd.format = 
            # format = 0 implies there is another payload
            # cmd.argument = 
            # cmd.payload
            # display(cmd)
            resize!(buf, sizeof(msg))
            push!(bufs, buf)
        end
    end
    if !isempty(bufs)
        Aeron.publisher(ctx, conf) do pub
            for buf in bufs
                status = put!(pub, buf)
                if status != :success
                    @warn "Message not published. Stopping." status
                    errorcode += 1
                    break
                end
                sleep(0.001)
            end
        end
    end
    if isempty(array_flags) && isempty(command_flags)
        println(stderr, "no action provided")
        errorcode = 127
    end
    return errorcode
end


function julia_main()::Cint
    return main(ARGS)::Cint
end

end

#=
Example receiver:

 Aeron.subscriber(ctx, conf) do sub
        for frame in sub
            msg = SpidersMessageEncoding.sbedecode(frame.buffer)
            if msg isa CommandMessage
                println(msg.command, " = ", string(getargument(msg))[1:min(20,end)])
            elseif msg isa CommitMessage
                println("COMMIT")
            elseif msg isa TensorMessage || msg isa ArrayMessage
                println("tensor")
                display(arraydata(msg))
            end
        end
    end
=#