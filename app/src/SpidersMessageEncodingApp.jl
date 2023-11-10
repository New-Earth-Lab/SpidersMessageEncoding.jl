module SpidersMessageEncodingApp
using ArgParse
using AstroImages
using SpidersMessageEncoding
using Aeron

function main(ARGS)
    s = ArgParseSettings()
    @add_arg_table! s begin
        "channel"
            help = "aeron channel to publish to"
            arg_type = String
            required = true
        "stream"
            help = "aeron stream number to publish to"
            arg_type = Int
            required = true
        "--command"
            nargs = '+'
            action = "append_arg"
            help = "SPIDERS command message entry to send (--command cmd [argument] [payload fits file path])"
            arg_type = String
        "--array"
            nargs = '+'
            action = "append_arg"
            help = "SPIDERS ArrayMessage entry to send (path to a FITS file)"
            arg_type = String
    end
    parsed_args = parse_args(ARGS, s)
    
    channel = parsed_args["channel"]
    stream = parsed_args["stream"]

    conf = AeronConfig(;channel, stream)
    ctx = AeronContext()

    commands = parsed_args["command"]
    array = parsed_args["array"]
    if !isempty(commands)
        display(commands)
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
    if !isempty(array)
        println("TODO")
        return 0
    end
    println(stderr, "no action provided")
    return 1
end


function julia_main()::Cint
    return main(ARGS)::Cint
  end

end