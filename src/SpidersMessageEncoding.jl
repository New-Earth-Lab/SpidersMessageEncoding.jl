module SpidersMessageEncoding

using SimpleBinaryEncoding
# evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/image.xml"))
# evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/dmcommand.xml"))
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/command.xml"))
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/tensor.xml"))

# To set string contents without allocations, users should use StaticString.
# Reexport the key string macros for their use.
using StaticStrings
export @static_str, @cstatic_str, MessageHeader, ArrayMessage, arraydata, arraydata!

const MessageHeader = messageHeader

# Type alias for union of different array shapes

buffertype(d::TensorMessage{T}) where T = T

# We want to create copies of TensorMessage that have a specific dimensionality
# This is to allow easier type-stable access to the underlying data for the user.
struct ArrayMessage{N,T}
    tensor::TensorMessage{T}
    function ArrayMessage{N}(args...; kwargs...) where N
        tensor = TensorMessage(args...; kwargs...)
        return new{N,buffertype(tensor)}(tensor)
    end
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
    0x0140011F => Float64
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
        if p[2] == DType
            return p[1]
        end
    end
    error(lazy"Datatype $DType not found in list of supported pixel formats $(pixformat_pairs)")
end
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
Base.ndims(::ArrayMessage{N}) where N = N
Base.size(img::ArrayMessage) = Int.(img.shape[1:ndims(img)])


"""
Function to view an TensorMessage.values as an array of the
correct data type and dimensions.

Note: This function is not type stable since it infers the 
data type from the `TensorMessage.format` field. See the method
`frameArray(DType, img)` for a type-stable version that allows
you to assume a given format (and error if mismatched).

If you can assume that the data type is not changing
while subscribed to a stream, a good pattern is to 
get the pixel format from an initial image and then
use it inside a function barrier:
```julia
Aeron.subscribe(aeron_conf) do aeronsub

    # Get a first frame and fetch the data type 
    # dynamically
    first_frame = first(aeronsub)
    first_img = TensorMessage(first_frame.buffer)
    pixmat = arraydata(first_img)
    ElType = eltype(pixmat)
    # Process the first image using this dynamically
    # determined type. Continue after the function barrier.
    process_image(pixmat)

    # Function barrier: this lets Julia compile
    # code that is specialized to this image 
    # pixel format. After the first image,
    # this will be really fast.
    letsgo(aeronsub, ElType)
end

function letsgo(aeronsub, ElType)
    for frame in subscription
        img = TensorMessage(first_frame.buffer)
        # Note the extra first argument! 
        pixmat = arraydata(ElType, img) 
        # use pixmat here:
        process_image(pixmat)
    end
end

function process_image(img)
    # Use image data here.
    # typeof(img) == Matrix{Float32}
end
```
"""
function arraydata(img::ArbArrayMessage)
    # Not type-stable. It's conceivable
    # that it could constant propagate in future
    # versions of Julia.
    ElType = eltype(img)
    return arraydata(ElType, img)
end
function arraydata(Eltype::Type{T}, img::ArbArrayMessage) where T
    data = img.values
    @boundscheck if mod(length(data), sizeof(Eltype)) != 0
        error("length of data is not a multiple of the element type")
    end
    # TODO: check element type
    reint =  @inbounds reinterpret(
        Eltype,
        data,
    )
    reshp = @inbounds reshape(
        reint,
        size(img)
    )
    return reshp
end

function arraydata!(img::ArbArrayMessage, pixdat::Array{ElType}) where ElType
    img.format = pixel_format_from_dtype(ElType)
    resize!(img.values, prod(size(pixdat))*sizeof(ElType))
    sz1 = size(pixdat,1)
    sz2 = sz3 = sz4 = 0
    if ndims(img) >= 2
        sz2 = size(pixdat,2)
    end
    if ndims(img) >= 3
        sz3 = size(pixdat,3)
    end
    if ndims(img) >= 4
        sz4 = size(pixdat,4)
    end
    img.shape = (sz1,sz2,sz3,sz4)
    arraydata(ElType, img) .= pixdat
    return arraydata(ElType, img)
end


# # Piracy: this isn't actually type piracy since we own
# # these types, even though they were defined for us by SimpleBinaryEncoding/

"""
Convenience constructor for creating taking a 2D array and byte buffer,
and formatting it as an `TensorMessage` with width, height, format, and data type
taken from the 2D array, then copying the data.
"""
function ArrayMessage(buffer::AbstractVector{UInt8}, pixdat::Array{T,N}) where {T,N}
    if N > 4
        error("only up to 4D arrays are supported")
    end
    img = ArrayMessage{N}(buffer)
    arraydata!(img, pixdat)
    return img
end

end;