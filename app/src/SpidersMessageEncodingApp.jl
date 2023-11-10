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
            help = "SPIDERS command message entry to send (--command cmd [argument] [payload fits file path])"
            arg_type = String
        "--array"
            nargs = '?'
            help = "SPIDERS ArrayMessage entry to send (path to a FITS file)"
            arg_type = String
    end
    parsed_args = parse_args(ARGS, s)
    if isnothing(parsed_args)
        return 1
    end

    dir = parsed_args["dir"]
    uri = parsed_args["uri"]
    stream = parsed_args["stream"]

    ctx = AeronContext(;dir)
    conf = AeronConfig(;uri, stream)

    commands = parsed_args["cmd"]
    array = parsed_args["array"]
    if !isempty(commands)
        # Prepare all messages first, and then send one after another without pause
        messages = map(commands) do argstr
            buf = zeros(UInt8, 100000)
            cmd = CommandMessage(buf)
            # cmd.timestamp = 
            # cmd.format = 
            # format = 0 implies there is another payload
            # cmd.argument = 
            # cmd.payload
            # display(cmd)
            resize!(buf, sizeof(cmd))
            buf
        end
        errorcode = 0
        Aeron.publisher(ctx, conf) do pub
            for message in messages
                status = put!(pub, message)
                if status != :success
                    @warn "message not published" status
                    errorcode += 1
                end
            end
        end
        return errorcode
    end
    if !isnothing(array)

        @info "sending array message"
        data = FITS(array, "r")  do hdus
            read(hdus[1])
        end
        
        buf = zeros(UInt8, 100+length(data)*sizeof(data))
        msg = TensorMessage(buf)
        @show size(data) sizeof(data) length(data)
        # FITS files are always at least 2d. If we get a single column, treat this as a vector.
        if ndims(data) == 2 && size(data,2) == 1
            data = dropdims(data,dims=2)
            @info "dropping trailing dimension of size 1"
        end
        arraydata!(msg, data)
        display(msg)
        # cmd.timestamp = 
        # cmd.format = 
        # format = 0 implies there is another payload
        # cmd.argument = 
        # cmd.payload
        # display(cmd)
        resize!(buf, sizeof(msg))
        errorcode = 0
        Aeron.publisher(ctx, conf) do pub
            status = put!(pub, buf)
            if status != :success
                @warn "message not published" status
                errorcode += 1
            end
        end
        return errorcode
    end
    println(stderr, "no action provided")
    return 1
end


function julia_main()::Cint
    return main(ARGS)::Cint
  end

end