module SpidersMessageEncoding

using SimpleBinaryEncoding
# evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/image.xml"))
# evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/dmcommand.xml"))
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/command.xml"))
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/tensor.xml"))

# To set string contents without allocations, users should use StaticString.
# Reexport the key string macros for their use.
using StaticStrings
export @static_str, @cstatic_str, MessageHeader, ArrayMessage, TensorMessage, CommandMessage, arraydata, arraydata!, tensormessage, getargument, setargument!

const MessageHeader = messageHeader


buffertype(d::TensorMessage{T}) where T = T
# Type alias for union of different array shapes

# We want to create copies of TensorMessage that have a specific dimensionality
# This is to allow easier type-stable access to the underlying data for the user.
struct ArrayMessage{T<:Any,N,TensorType}
    tensor::TensorMessage{TensorType}
    function ArrayMessage{T,N}(args...; kwargs...) where {T,N}
        tensor = TensorMessage(args...; kwargs...)
        tensor.format = pixel_format_from_dtype(T) # type-unstable but should const-prop
        return new{T,N,buffertype(tensor)}(tensor)
    end
    function ArrayMessage{T,N,BT}(args...; kwargs...) where {T,N,BT}
        tensor = TensorMessage{BT}(args...; kwargs...)
        tensor.format = pixel_format_from_dtype(T) # type-unstable but should const-prop
        return new{T,N,BT}(tensor)
    end
end
# Type-unstable constructor.
function tensormessage(buffer::AbstractVector{<:UInt8})
    tensor = TensorMessage(buffer)
    if tensor.format == 0
        return TensorMessage(buffer)
    end
    return ArrayMessage{eltype(tensor),ndims(tensor)}(buffer)
end

# Forward to tensor
@inline Base.getproperty(msg::ArrayMessage, prop::Symbol) = @inline getproperty(getfield(msg, :tensor), prop)
@inline Base.setproperty!(msg::ArrayMessage, prop::Symbol, value) = setproperty!(getfield(msg, :tensor), prop::Symbol, value)
Base.sizeof(msg::ArrayMessage) = sizeof(getfield(msg, :tensor))
Base.propertynames(msg::ArrayMessage) = propertynames(getfield(msg, :tensor))
Base.show(io::IO, mime::MIME"text/plain", msg::ArrayMessage) = Base.show(io::IO, mime, getfield(msg, :tensor))

# type alias to refer to either specified dimension ArrayMessage or TensorMessage
ArbArrayMessage = Union{ArrayMessage, TensorMessage}

# Define some higher level functions to make working
# with these types a little more convenient

function Base.eltype(img::ArbArrayMessage)
    return pixel_dtype_from_format(img.format)
end

# This is not type stable
Base.ndims(ten::TensorMessage) = count(>(0), ten.shape)
function Base.size(ten::TensorMessage)
    if ten.shape[2] == 0
        return (Int(ten.shape[1]),)
    elseif ten.shape[3] == 0
        return (Int(ten.shape[1]), Int(ten.shape[2]))
    elseif ten.shape[4] == 0
        return (Int(ten.shape[1]), Int(ten.shape[2]), Int(ten.shape[3]))
    else
        return (Int(ten.shape[1]), Int(ten.shape[2]), Int(ten.shape[3]), Int(ten.shape[4]))
    end
end
# This is; hence why we created ArrayMessage. It's just a TensorMessage 
# with the `ndims` tracked by the type-system.
Base.ndims(::ArrayMessage{T,N}) where {T,N} = N
Base.size(img::ArrayMessage) = Int.(img.shape[1:ndims(img)])



const pixformat_pairs = (
    # From GenI cam spec:
    0x01080116 => UInt8,
    0x01080117 => Int8,
    0x01100118 => UInt16,
    0x01100119 => Int16,
    0x0120011A => UInt32,
    0x0120011B => Int32,
    0x0120011C => Float32,
    0x0140011D => UInt64,
    0x0140011E => Int64,
    0x0140011F => Float64,

    # Our codes: for storing another message type inside a variable length field
    0xF0F0F0F0 => TensorMessage
)
# Not type-stable (return is union of all possible pixel types)
function pixel_dtype_from_format(format::Integer) 
    for p in pixformat_pairs
        if p[1] == format
            return p[2]
        end
    end
    error(lazy"Format $format not recognized")
end
# Type-stable and should const-propagate
function pixel_format_from_dtype(DType::Type)
    for p in pixformat_pairs
        # if p[2] == DType
        if DType <: p[2]
            return p[1]
        end
    end
    error(lazy"Datatype $DType not found in list of supported pixel formats $(pixformat_pairs)")
end

function arraymessagetype(tensor::ArbArrayMessage)
    return ArrayMessage{eltype(tensor),ndims(tensor)}
end

"""
Aeron.subscribe(aeron_conf) do aeronsub

    # Get a first frame and fetch the data type 
    # dynamically
    first_data = first(aeronsub)

    # determine size and shape dynamically
    first_message = tensormessage(first_data.buffer)

    # Process the first image using this dynamically
    # determined type.
    process_image(first_message)

    # Function barrier: this lets Julia compile
    # code that is specialized to this image 
    # pixel format. After the first image,
    # this will be really fast.
    letsgo(aeronsub, typeof(first_message))
end

function letsgo(aeronsub, ::Type{T}) where T
    for frame in aeronsub
        img = T(frame.buffer)
        # Note the extra first argument! 
        pixmat = arraydata(ElType, img) 
        # use pixmat here:
        process_image(pixmat)
    end
end

function process_image(img)
    # Use image data here with zero-allocations
    data = arraydata(img)
end
```
"""
function ArrayMessage(tensor::ArbArrayMessage)
    return ArrayMessage{eltype(tensor),ndims(tensor)}(
        getfield(tensor, :buffer)
    )
end


"""
Function to view an TensorMessage.values or ArrayMessage.values
as an array of the correct data type and dimensions.
This function will be type-stable and allocation-free if used on
an `ArrayMessage{ElType,Dim}` but not on a generic `TensorMessage`.
"""
function arraydata(img::TensorMessage)
    data = img.values
    ElType = eltype(img)
    @boundscheck if mod(length(data), sizeof(ElType)) != 0
        error("length of data is not a multiple of the element type")
    end
    reint =  @inbounds reinterpret(
        ElType, # unstable for unspecialized TensorMessage
        data,
    )
    reshp = @inbounds reshape(
        reint,
        size(img)
    )
    return reshp
end
function arraydata(img::ArrayMessage{T,N}) where {T,N}
    data = img.values
    @boundscheck if mod(length(data), sizeof(T)) != 0
        error("length of data is not a multiple of the element type")
    end
    reint =  @inbounds reinterpret(
        T, # unstable for unspecialized TensorMessage
        data,
    )
    reshp = @inbounds reshape(
        reint,
        size(img)
    )
    return reshp
end

function arraydata!(img::TensorMessage, pixdat::Array{ElType}) where ElType
    return _arraydata!(ElType, img, pixdat)
end
# For ArrayMessage, the user has already specified the element type in the message type parameter
function arraydata!(img::ArrayMessage{ElType}, pixdat::Array) where ElType
    return _arraydata!(ElType, img, pixdat)
end
function _arraydata!(t::Type{ElType}, img::ArbArrayMessage, pixdat) where ElType
    img.format = pixel_format_from_dtype(ElType)
    resize!(img.values, prod(size(pixdat))*sizeof(ElType))
    sz1 = sz2 = sz3 = sz4 = 0
    if ndims(pixdat) >= 1
        sz1 = size(pixdat,1)
    end
    if ndims(pixdat) >= 2
        sz2 = size(pixdat,2)
    end
    if ndims(pixdat) >= 3
        sz3 = size(pixdat,3)
    end
    if ndims(pixdat) >= 4
        sz4 = size(pixdat,4)
    end
    img.shape = (sz1,sz2,sz3,sz4)
    a = arraydata(img)
    a .= pixdat
    return a
end


# # Piracy: this isn't actually type piracy since we own
# # these types, even though they were defined for us by SimpleBinaryEncoding/

"""
Convenience constructor for creating taking a 2D array and byte buffer,
and formatting it as an `TensorMessage` with width, height, format, and data type
taken from the 2D array, then copying the data.
"""
function tensormessage(buffer::AbstractVector{UInt8}, pixdat::Array{T,N}) where {T,N}
    if N > 4
        error("only up to 4D arrays are supported")
    end
    img = ArrayMessage{T,N}(buffer)
    arraydata!(img, pixdat)
    return img
end # TODO: test


######################### Command Message handling ############
function Base.eltype(cmd::CommandMessage)
    return pixel_dtype_from_format(cmd.format)
end
function getargument(cmd::CommandMessage)::Union{last.(SpidersMessageEncoding.pixformat_pairs)...} # Too long to actually union-split
    data = cmd.value
    ElType = eltype(cmd)
    if ElType <: SimpleBinaryEncoding.AbstractMessage
        return ElType(data)
    else
        @boundscheck if length(data) != sizeof(ElType)
            error("length of data is not correct for the element type")
        end
        reint = @inbounds reinterpret(
            ElType, # unstable
            data,
        )
        return reint[]
    end
end
function setargument!(cmd::CommandMessage, value::ElType) where ElType
    cmd.format = pixel_format_from_dtype(ElType)
    resize!(cmd.value, sizeof(value))
    if ElType <: SimpleBinaryEncoding.AbstractMessage
        cmd.value .= view(getfield(value, :buffer), 1:sizeof(value))
    else
        reinterpret(
            ElType,
            cmd.value,
        )[] = value
    end
    return value
end


end;