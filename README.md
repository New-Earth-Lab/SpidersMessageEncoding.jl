# SpidersMessageEncoding.jl
Serialization and deserialization to/from binary using our SBE message definitions


## Examples
Initialize an ImageMessage:
```julia
julia> buf = zeros(UInt8,  10000);
julia> data = rand(Int16, 5, 8);
julia> img = Image(buf, data); # Initialize using a Julia array
julia> img.offsetX = 10;
julia> framearray(img) # View into buffer
5×8 reshape(reinterpret(Int16, ::SpidersMessageEncoding.varDataEncoding{...}), 5, 8) with eltype Int16:
 -15935   -3912   18329  -24829    -916  17506  -15568  -21337
 -11668  -18638   15420   26299   24322   -147   -7110  -29480
 -27119   -4356   -6978    -743    6621  15682   29171  -17794
   8352  -20918  -23085  -21558    4899  11529    8946   -9795
 -21654  -27246   -6669  -12071  -13846   4217  -23046   -6562

julia> framearray(Int16, img); # type-stable view into buffer.
```

Save to file (could be sent over network, mmap, Aeron, etc.) and recover:
```julia
julia> write("tmp.dat", buf)

julia> buf2 = read("tmp.dat")
julia> img2 = Image(buf2)
julia> framearray(img2)
5×8 reshape(reinterpret(Int16, ::SpidersMessageEncoding.varDataEncoding{...}), 5, 8) with eltype Int16:
 -15935   -3912   18329  -24829    -916  17506  -15568  -21337
 -11668  -18638   15420   26299   24322   -147   -7110  -29480
 -27119   -4356   -6978    -743    6621  15682   29171  -17794
   8352  -20918  -23085  -21558    4899  11529    8946   -9795
 -21654  -27246   -6669  -12071  -13846   4217  -23046   -6562

julia> img.offsetX
0x0000000a
```

