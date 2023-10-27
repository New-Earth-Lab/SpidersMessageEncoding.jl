module SpidersMessageEncoding

using SimpleBinaryEncoding
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/image.xml"))
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/dmcommand.xml"))

const MessageHeader = messageHeader
export MessageHeader, Image, DmCommand

# Define some higher level functions to make working
# with these types a little more convenient

# TODO: complete this list and make const.
#= const =# pixformat_pairs = (
    0 => Int16,
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
function Base.eltype(img::Image)
    return pixel_dtype_from_format(img.format)
end

function Base.size(img::Image)
    return (img.width, img.height)
end


"""
Function to view an Image.frameBuffer as a 2D array of the
correct data type and dimensions.

Note: This function is not type stable since it infers the 
data type from the `Image.format` field. See the method
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
    first_img = Image(first_frame.buffer)
    pixmat = framearray(first_img)
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
        img = Image(first_frame.buffer)
        # Note the extra first argument! 
        pixmat = framearray(ElType, img) 
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
function framearray(img::Image)
    # Not type-stable. It's conceivable
    # that it could constant propagate in future
    # versions of Julia.
    ElType = eltype(img)
    return framearray(ElType, img)
end
function framearray(Eltype, img::Image)
    reint = reinterpret(
        Eltype,
        img.frameBuffer
    )
    reshp = reshape(
        reint,
        Int(img.width),
        Int(img.height)
    )
    return reshp
end
export framearray

# Piracy: this isn't actually type piracy since we own
# these types, even though they were defined for us by SimpleBinaryEncoding/

"""
Convenience constructor for creating taking a 2D array and byte buffer,
and formatting it as an `Image` with width, height, format, and data type
taken from the 2D array, then copying the data.
"""
function Image(buffer::AbstractVector{UInt8}, pixmat::Matrix)
    ElType = eltype(pixmat)

    img = Image(buffer)
    img.format = pixel_format_from_dtype(ElType)
    resize!(img.frameBuffer, size(pixmat,1)* size(pixmat,2)*sizeof(ElType))
    img.width = size(pixmat,1)
    img.height = size(pixmat,2)
    framearray(ElType, img) .= pixmat

    return img

end

end;